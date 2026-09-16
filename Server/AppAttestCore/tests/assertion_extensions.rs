use base64::{engine::general_purpose::STANDARD, Engine};
use opencast_app_attest_core::app_attest::{
    request_client_data_hash, verify_assertion, AppAttestError,
};
use p256::ecdsa::{signature::Signer, Signature, SigningKey};
use sha2::{Digest, Sha256};

const APP_ID: &str = "EXAMPLETEAM.com.example.opencast";

fn extension_map(category_key: &str, version_key: &str, category: u8) -> Vec<u8> {
    let mut result = vec![0xa2];
    cbor_string(&mut result, 3, category_key.as_bytes());
    cbor_string(&mut result, 2, &u32::from(category).to_le_bytes());
    cbor_string(&mut result, 3, version_key.as_bytes());
    cbor_string(&mut result, 3, b"123");
    result
}

fn cbor_string(output: &mut Vec<u8>, major: u8, bytes: &[u8]) {
    assert!(bytes.len() < 256);
    if bytes.len() < 24 {
        output.push((major << 5) | bytes.len() as u8);
    } else {
        output.extend_from_slice(&[(major << 5) | 24, bytes.len() as u8]);
    }
    output.extend_from_slice(bytes);
}

fn authenticator_data(flags: u8, suffix: &[u8]) -> Vec<u8> {
    let mut result = Sha256::digest(APP_ID.as_bytes()).to_vec();
    result.push(flags);
    result.extend_from_slice(&7u32.to_be_bytes());
    result.extend_from_slice(suffix);
    result
}

fn signed_assertion(auth_data: &[u8]) -> (String, Vec<u8>, [u8; 32]) {
    let key = SigningKey::from_slice(&[1u8; 32]).unwrap();
    let hash = request_client_data_hash("POST", "/v1/devices/register", "fixture");
    let mut input = auth_data.to_vec();
    input.extend_from_slice(&hash);
    let signature: Signature = key.sign(&Sha256::digest(input));
    let mut cbor = vec![0xa2];
    cbor_string(&mut cbor, 3, b"authenticatorData");
    cbor_string(&mut cbor, 2, auth_data);
    cbor_string(&mut cbor, 3, b"signature");
    cbor_string(&mut cbor, 2, signature.to_der().as_bytes());
    (
        STANDARD.encode(cbor),
        key.verifying_key()
            .to_encoded_point(false)
            .as_bytes()
            .to_vec(),
        hash,
    )
}

#[test]
fn legacy_and_extended_assertions_verify_with_replay_and_request_binding() {
    let extensions = extension_map("validationCategory", "bundleVersion", 2);
    let prefixed = extension_map("apple_validation_category_01", "apple_bundle_version_01", 4);
    for (flags, suffix) in [(0x40, &[][..]), (0xc0, &extensions), (0x80, &prefixed)] {
        let (assertion, key, hash) = signed_assertion(&authenticator_data(flags, suffix));
        let result = verify_assertion(&assertion, &hash, APP_ID, &key, 0).unwrap();
        assert_eq!(result.sign_counter, 7);
        assert!(matches!(
            verify_assertion(&assertion, &hash, APP_ID, &key, 7),
            Err(AppAttestError::InvalidCounter)
        ));
        assert!(matches!(
            verify_assertion(&assertion, &[0; 32], APP_ID, &key, 0),
            Err(AppAttestError::InvalidSignature)
        ));
        assert!(matches!(
            verify_assertion(&assertion, &hash, "other.app", &key, 0),
            Err(AppAttestError::InvalidAppId)
        ));
    }
}

#[test]
fn extension_bytes_are_covered_by_the_signature() {
    let data = authenticator_data(
        0xc0,
        &extension_map("validationCategory", "bundleVersion", 2),
    );
    let (assertion, key, hash) = signed_assertion(&data);
    let mut cbor = STANDARD.decode(assertion).unwrap();
    let version = cbor.windows(3).position(|window| window == b"123").unwrap();
    cbor[version] = b'9';
    assert!(matches!(
        verify_assertion(&STANDARD.encode(cbor), &hash, APP_ID, &key, 0),
        Err(AppAttestError::InvalidSignature)
    ));
}

#[test]
fn malformed_or_unflagged_extensions_are_rejected_even_when_signed() {
    let valid = extension_map("validationCategory", "bundleVersion", 2);
    let mut trailing = valid.clone();
    trailing.push(0);
    let mut duplicate = extension_map("validationCategory", "bundleVersion", 2);
    duplicate[0] = 0xa3;
    cbor_string(&mut duplicate, 3, b"apple_validation_category_01");
    duplicate.push(2);
    let invalid_category = extension_map("validationCategory", "bundleVersion", 0);
    for (flags, suffix) in [
        (0x40, valid.as_slice()),
        (0xc0, &[]),
        (0xc0, &[0x00]),
        (0xc0, &valid[..valid.len() - 1]),
        (0xc0, &trailing),
        (0xc0, &duplicate),
        (0xc0, &invalid_category),
    ] {
        let (assertion, key, hash) = signed_assertion(&authenticator_data(flags, suffix));
        assert!(matches!(
            verify_assertion(&assertion, &hash, APP_ID, &key, 0),
            Err(AppAttestError::InvalidAssertionFormat)
        ));
    }
}
