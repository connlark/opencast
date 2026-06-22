use base64::{engine::general_purpose, Engine};
use byteorder::{BigEndian, ByteOrder};
use p256::ecdsa::{
    signature::{hazmat::PrehashVerifier, Verifier},
    DerSignature as P256DerSignature, Signature as P256Signature, VerifyingKey as P256VerifyingKey,
};
use p384::ecdsa::{DerSignature as P384DerSignature, VerifyingKey as P384VerifyingKey};
use sha2::{Digest, Sha256, Sha384};
use std::{error::Error, fmt};
use x509_parser::prelude::{FromDer, X509Certificate};
use x509_parser::time::ASN1Time;

const APP_ATTEST: &[u8] = b"appattest";
const APP_ATTEST_DEVELOP: &[u8] = b"appattestdevelop";
const AUTHENTICATOR_DATA_LEN: usize = 37;
const MAX_APP_ATTEST_CERTIFICATES: u64 = 3;
const APPLE_ROOT_CERT_PEM: &[u8] = include_bytes!("apple_app_attestation_root_ca.pem");

const OID_ECDSA_SHA256: &str = "1.2.840.10045.4.3.2";
const OID_ECDSA_SHA384: &str = "1.2.840.10045.4.3.3";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AppAttestError {
    InvalidAttestationFormat,
    InvalidAssertionFormat,
    InvalidAaguid,
    InvalidAppId,
    InvalidCertificate,
    InvalidChallenge,
    InvalidCounter,
    InvalidCredentialId,
    InvalidKeyId,
    InvalidNonce,
    InvalidPublicKey,
    InvalidSignature,
    UnsupportedAlgorithm,
}

impl AppAttestError {
    pub fn code(&self) -> &'static str {
        match self {
            AppAttestError::InvalidAttestationFormat => "invalid_attestation_format",
            AppAttestError::InvalidAssertionFormat => "invalid_assertion_format",
            AppAttestError::InvalidAaguid => "invalid_aaguid",
            AppAttestError::InvalidAppId => "invalid_app_id",
            AppAttestError::InvalidCertificate => "invalid_certificate",
            AppAttestError::InvalidChallenge => "invalid_challenge",
            AppAttestError::InvalidCounter => "invalid_counter",
            AppAttestError::InvalidCredentialId => "invalid_credential_id",
            AppAttestError::InvalidKeyId => "invalid_key_id",
            AppAttestError::InvalidNonce => "invalid_nonce",
            AppAttestError::InvalidPublicKey => "invalid_public_key",
            AppAttestError::InvalidSignature => "invalid_signature",
            AppAttestError::UnsupportedAlgorithm => "unsupported_algorithm",
        }
    }
}

impl fmt::Display for AppAttestError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.code())
    }
}

impl Error for AppAttestError {}

pub struct AttestationVerification {
    pub public_key: Vec<u8>,
}

pub struct AssertionVerification {
    pub sign_counter: u32,
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

pub fn challenge_hash(challenge: &str) -> String {
    sha256_hex(challenge.as_bytes())
}

pub fn request_client_data_hash(method: &str, path: &str, payload: &str) -> [u8; 32] {
    let payload_hash = sha256_hex(payload.as_bytes());
    let binding = format!("{method}\n{path}\n{payload_hash}");
    Sha256::digest(binding.as_bytes()).into()
}

pub fn canonical_key_id(key_id: &str) -> Result<String, AppAttestError> {
    Ok(general_purpose::STANDARD.encode(decode_key_id(key_id)?))
}

pub fn verify_attestation(
    attestation_object_base64: &str,
    challenge: &str,
    app_id: &str,
    key_id: &str,
    environment: &str,
    now_seconds: i64,
) -> Result<AttestationVerification, AppAttestError> {
    if challenge.is_empty() {
        return Err(AppAttestError::InvalidChallenge);
    }

    let cbor = decode_base64(attestation_object_base64)?;
    let attestation = Attestation::from_cbor(&cbor)?;
    verify_certificate_chain(&attestation.certificates, now_seconds)?;

    let authenticator_data = AuthenticatorData::new(attestation.auth_data)?;
    let key_id_bytes = decode_key_id(key_id)?;
    let public_key = extract_certificate_public_key(attestation.certificates[0])?;

    let public_key_hash: [u8; 32] = Sha256::digest(&public_key).into();
    if public_key_hash.as_slice() != key_id_bytes.as_slice() {
        return Err(AppAttestError::InvalidPublicKey);
    }

    authenticator_data.verify_app_id(app_id)?;
    authenticator_data.verify_initial_counter()?;
    authenticator_data.verify_aaguid(environment)?;
    authenticator_data.verify_key_id(&key_id_bytes)?;

    let client_data_hash: [u8; 32] = Sha256::digest(challenge.as_bytes()).into();
    let nonce = auth_data_nonce(attestation.auth_data, &client_data_hash);
    let certificate_nonce = extract_nonce_from_cert(attestation.certificates[0])?;
    if nonce != certificate_nonce {
        return Err(AppAttestError::InvalidNonce);
    }

    Ok(AttestationVerification { public_key })
}

pub fn verify_assertion(
    assertion_base64: &str,
    client_data_hash: &[u8; 32],
    app_id: &str,
    public_key: &[u8],
    previous_counter: u32,
) -> Result<AssertionVerification, AppAttestError> {
    let cbor = decode_base64(assertion_base64)?;
    let assertion = Assertion::from_cbor(&cbor)?;
    let authenticator_data = AuthenticatorData::new(assertion.authenticator_data)?;
    authenticator_data.verify_app_id(app_id)?;

    if authenticator_data.counter <= previous_counter {
        return Err(AppAttestError::InvalidCounter);
    }

    let nonce = auth_data_nonce(assertion.authenticator_data, client_data_hash);
    let signature = P256Signature::from_der(assertion.signature)
        .map_err(|_| AppAttestError::InvalidSignature)?;
    let verifying_key = P256VerifyingKey::from_sec1_bytes(public_key)
        .map_err(|_| AppAttestError::InvalidPublicKey)?;

    verifying_key
        .verify(&nonce, &signature)
        .map_err(|_| AppAttestError::InvalidSignature)?;

    Ok(AssertionVerification {
        sign_counter: authenticator_data.counter,
    })
}

fn decode_base64(value: &str) -> Result<Vec<u8>, AppAttestError> {
    general_purpose::STANDARD
        .decode(value)
        .or_else(|_| general_purpose::URL_SAFE_NO_PAD.decode(value))
        .map_err(|_| AppAttestError::InvalidAttestationFormat)
}

fn decode_key_id(key_id: &str) -> Result<[u8; 32], AppAttestError> {
    let bytes = decode_base64(key_id)?;
    bytes.try_into().map_err(|_| AppAttestError::InvalidKeyId)
}

fn auth_data_nonce(authenticator_data: &[u8], client_data_hash: &[u8; 32]) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(authenticator_data);
    hasher.update(client_data_hash);
    hasher.finalize().into()
}

struct Attestation<'a> {
    certificates: Vec<&'a [u8]>,
    auth_data: &'a [u8],
}

impl<'a> Attestation<'a> {
    fn from_cbor(cbor: &'a [u8]) -> Result<Self, AppAttestError> {
        let mut decoder = minicbor::Decoder::new(cbor);
        let Some(entries) = decoder
            .map()
            .map_err(|_| AppAttestError::InvalidAttestationFormat)?
        else {
            return Err(AppAttestError::InvalidAttestationFormat);
        };

        let mut certificates: Option<Vec<&'a [u8]>> = None;
        let mut auth_data: Option<&'a [u8]> = None;
        let mut saw_format = false;

        for _ in 0..entries {
            let key = decoder
                .str()
                .map_err(|_| AppAttestError::InvalidAttestationFormat)?;

            match key {
                "fmt" => {
                    let value = decoder
                        .str()
                        .map_err(|_| AppAttestError::InvalidAttestationFormat)?;
                    if value != "apple-appattest" {
                        return Err(AppAttestError::InvalidAttestationFormat);
                    }
                    saw_format = true;
                }
                "attStmt" => {
                    certificates = Some(parse_attestation_statement(&mut decoder)?);
                }
                "authData" => {
                    auth_data = Some(
                        decoder
                            .bytes()
                            .map_err(|_| AppAttestError::InvalidAttestationFormat)?,
                    );
                }
                _ => decoder
                    .skip()
                    .map_err(|_| AppAttestError::InvalidAttestationFormat)?,
            }
        }

        if !saw_format {
            return Err(AppAttestError::InvalidAttestationFormat);
        }

        let certificates = certificates.ok_or(AppAttestError::InvalidAttestationFormat)?;
        if certificates.is_empty() {
            return Err(AppAttestError::InvalidAttestationFormat);
        }

        Ok(Self {
            certificates,
            auth_data: auth_data.ok_or(AppAttestError::InvalidAttestationFormat)?,
        })
    }
}

fn parse_attestation_statement<'a>(
    decoder: &mut minicbor::Decoder<'a>,
) -> Result<Vec<&'a [u8]>, AppAttestError> {
    let Some(entries) = decoder
        .map()
        .map_err(|_| AppAttestError::InvalidAttestationFormat)?
    else {
        return Err(AppAttestError::InvalidAttestationFormat);
    };
    let mut certificates: Option<Vec<&'a [u8]>> = None;

    for _ in 0..entries {
        let key = decoder
            .str()
            .map_err(|_| AppAttestError::InvalidAttestationFormat)?;
        match key {
            "x5c" => {
                let Some(count) = decoder
                    .array()
                    .map_err(|_| AppAttestError::InvalidAttestationFormat)?
                else {
                    return Err(AppAttestError::InvalidAttestationFormat);
                };
                if count == 0 || count > MAX_APP_ATTEST_CERTIFICATES {
                    return Err(AppAttestError::InvalidAttestationFormat);
                }

                let mut parsed = Vec::with_capacity(count as usize);
                for _ in 0..count {
                    parsed.push(
                        decoder
                            .bytes()
                            .map_err(|_| AppAttestError::InvalidAttestationFormat)?,
                    );
                }
                certificates = Some(parsed);
            }
            _ => decoder
                .skip()
                .map_err(|_| AppAttestError::InvalidAttestationFormat)?,
        }
    }

    certificates.ok_or(AppAttestError::InvalidAttestationFormat)
}

struct Assertion<'a> {
    authenticator_data: &'a [u8],
    signature: &'a [u8],
}

impl<'a> Assertion<'a> {
    fn from_cbor(cbor: &'a [u8]) -> Result<Self, AppAttestError> {
        let mut decoder = minicbor::Decoder::new(cbor);
        let Some(entries) = decoder
            .map()
            .map_err(|_| AppAttestError::InvalidAssertionFormat)?
        else {
            return Err(AppAttestError::InvalidAssertionFormat);
        };

        let mut authenticator_data: Option<&'a [u8]> = None;
        let mut signature: Option<&'a [u8]> = None;

        for _ in 0..entries {
            let key = decoder
                .str()
                .map_err(|_| AppAttestError::InvalidAssertionFormat)?;
            match key {
                "authenticatorData" => {
                    let bytes = decoder
                        .bytes()
                        .map_err(|_| AppAttestError::InvalidAssertionFormat)?;
                    if bytes.len() != AUTHENTICATOR_DATA_LEN {
                        return Err(AppAttestError::InvalidAssertionFormat);
                    }
                    authenticator_data = Some(bytes);
                }
                "signature" => {
                    signature = Some(
                        decoder
                            .bytes()
                            .map_err(|_| AppAttestError::InvalidAssertionFormat)?,
                    );
                }
                _ => decoder
                    .skip()
                    .map_err(|_| AppAttestError::InvalidAssertionFormat)?,
            }
        }

        Ok(Self {
            authenticator_data: authenticator_data.ok_or(AppAttestError::InvalidAssertionFormat)?,
            signature: signature.ok_or(AppAttestError::InvalidAssertionFormat)?,
        })
    }
}

struct AuthenticatorData<'a> {
    rp_id_hash: [u8; 32],
    counter: u32,
    aaguid: Option<&'a [u8]>,
    credential_id: Option<&'a [u8]>,
}

impl<'a> AuthenticatorData<'a> {
    fn new(bytes: &'a [u8]) -> Result<Self, AppAttestError> {
        if bytes.len() < AUTHENTICATOR_DATA_LEN {
            return Err(AppAttestError::InvalidAssertionFormat);
        }

        let mut data = Self {
            rp_id_hash: bytes[0..32]
                .try_into()
                .map_err(|_| AppAttestError::InvalidAssertionFormat)?,
            counter: BigEndian::read_u32(&bytes[33..37]),
            aaguid: None,
            credential_id: None,
        };

        if bytes.len() > AUTHENTICATOR_DATA_LEN && bytes.len() < 55 {
            return Err(AppAttestError::InvalidAttestationFormat);
        }

        if bytes.len() >= 55 {
            let credential_id_len = BigEndian::read_u16(&bytes[53..55]) as usize;
            if credential_id_len != 32 {
                return Err(AppAttestError::InvalidCredentialId);
            }
            let credential_end = 55usize
                .checked_add(credential_id_len)
                .ok_or(AppAttestError::InvalidAttestationFormat)?;
            if bytes.len() < credential_end {
                return Err(AppAttestError::InvalidAttestationFormat);
            }
            data.aaguid = Some(&bytes[37..53]);
            data.credential_id = Some(&bytes[55..credential_end]);
        }

        Ok(data)
    }

    fn verify_app_id(&self, app_id: &str) -> Result<(), AppAttestError> {
        let expected: [u8; 32] = Sha256::digest(app_id.as_bytes()).into();
        if self.rp_id_hash == expected {
            Ok(())
        } else {
            Err(AppAttestError::InvalidAppId)
        }
    }

    fn verify_initial_counter(&self) -> Result<(), AppAttestError> {
        if self.counter == 0 {
            Ok(())
        } else {
            Err(AppAttestError::InvalidCounter)
        }
    }

    fn verify_aaguid(&self, environment: &str) -> Result<(), AppAttestError> {
        let aaguid = self.aaguid.ok_or(AppAttestError::InvalidAaguid)?;
        let trimmed = trim_trailing_zeros(aaguid);

        match environment {
            "production" if trimmed == APP_ATTEST => Ok(()),
            "development" if trimmed == APP_ATTEST || trimmed == APP_ATTEST_DEVELOP => Ok(()),
            _ => Err(AppAttestError::InvalidAaguid),
        }
    }

    fn verify_key_id(&self, key_id: &[u8; 32]) -> Result<(), AppAttestError> {
        if self.credential_id == Some(key_id.as_slice()) {
            Ok(())
        } else {
            Err(AppAttestError::InvalidCredentialId)
        }
    }
}

fn trim_trailing_zeros(bytes: &[u8]) -> &[u8] {
    let end = bytes
        .iter()
        .rposition(|byte| *byte != 0)
        .map_or(0, |i| i + 1);
    &bytes[..end]
}

fn verify_certificate_chain(
    certificates: &[&[u8]],
    now_seconds: i64,
) -> Result<(), AppAttestError> {
    if certificates.len() < 2 || certificates.len() > MAX_APP_ATTEST_CERTIFICATES as usize {
        return Err(AppAttestError::InvalidCertificate);
    }

    let root_der = pem_to_der(APPLE_ROOT_CERT_PEM)?;
    let (_, root) =
        X509Certificate::from_der(&root_der).map_err(|_| AppAttestError::InvalidCertificate)?;
    let valid_at =
        ASN1Time::from_timestamp(now_seconds).map_err(|_| AppAttestError::InvalidCertificate)?;

    let mut parsed = Vec::with_capacity(certificates.len());
    for cert_der in certificates {
        let (_, cert) =
            X509Certificate::from_der(cert_der).map_err(|_| AppAttestError::InvalidCertificate)?;
        if !cert.validity().is_valid_at(valid_at) {
            return Err(AppAttestError::InvalidCertificate);
        }
        parsed.push(cert);
    }

    for issuer in parsed.iter().skip(1) {
        verify_issuer_ca_capability(issuer)?;
    }
    verify_issuer_ca_capability(&root)?;

    for pair in parsed.windows(2) {
        verify_signed_by(&pair[0], &pair[1])?;
    }

    verify_signed_by(
        parsed.last().ok_or(AppAttestError::InvalidCertificate)?,
        &root,
    )
}

fn verify_issuer_ca_capability(certificate: &X509Certificate<'_>) -> Result<(), AppAttestError> {
    let basic_constraints = certificate
        .basic_constraints()
        .map_err(|_| AppAttestError::InvalidCertificate)?
        .ok_or(AppAttestError::InvalidCertificate)?;
    let key_usage = certificate
        .key_usage()
        .map_err(|_| AppAttestError::InvalidCertificate)?;

    if !issuer_extension_values_allow_cert_signing(
        basic_constraints.value.ca,
        key_usage.map(|usage| usage.value.key_cert_sign()),
    ) {
        return Err(AppAttestError::InvalidCertificate);
    }

    Ok(())
}

fn issuer_extension_values_allow_cert_signing(
    basic_constraints_ca: bool,
    key_usage_key_cert_sign: Option<bool>,
) -> bool {
    basic_constraints_ca && key_usage_key_cert_sign.unwrap_or(true)
}

fn verify_signed_by(
    certificate: &X509Certificate<'_>,
    issuer: &X509Certificate<'_>,
) -> Result<(), AppAttestError> {
    if certificate.issuer().as_raw() != issuer.subject().as_raw() {
        return Err(AppAttestError::InvalidCertificate);
    }

    let signature_oid = certificate.signature_algorithm.algorithm.to_id_string();
    let signer_key = issuer.public_key().subject_public_key.data.as_ref();
    let signature = certificate.signature_value.data.as_ref();
    let tbs = certificate.tbs_certificate.as_ref();

    match signature_oid.as_str() {
        OID_ECDSA_SHA256 => {
            verify_ecdsa_signature(signer_key, signature, tbs, HashAlgorithm::Sha256)
                .map_err(|_| AppAttestError::InvalidCertificate)
        }
        OID_ECDSA_SHA384 => {
            verify_ecdsa_signature(signer_key, signature, tbs, HashAlgorithm::Sha384)
                .map_err(|_| AppAttestError::InvalidCertificate)
        }
        _ => Err(AppAttestError::UnsupportedAlgorithm),
    }
}

enum HashAlgorithm {
    Sha256,
    Sha384,
}

fn verify_ecdsa_signature(
    public_key: &[u8],
    signature: &[u8],
    message: &[u8],
    hash_algorithm: HashAlgorithm,
) -> Result<(), AppAttestError> {
    let digest = match hash_algorithm {
        HashAlgorithm::Sha256 => Sha256::digest(message).to_vec(),
        HashAlgorithm::Sha384 => Sha384::digest(message).to_vec(),
    };

    match public_key.len() {
        65 => {
            let key = P256VerifyingKey::from_sec1_bytes(public_key)
                .map_err(|_| AppAttestError::InvalidPublicKey)?;
            let signature = P256DerSignature::from_bytes(signature)
                .map_err(|_| AppAttestError::InvalidSignature)?;
            key.verify_prehash(&digest, &signature)
                .map_err(|_| AppAttestError::InvalidSignature)
        }
        97 => {
            let key = P384VerifyingKey::from_sec1_bytes(public_key)
                .map_err(|_| AppAttestError::InvalidPublicKey)?;
            let signature = P384DerSignature::from_bytes(signature)
                .map_err(|_| AppAttestError::InvalidSignature)?;
            key.verify_prehash(&digest, &signature)
                .map_err(|_| AppAttestError::InvalidSignature)
        }
        _ => Err(AppAttestError::InvalidPublicKey),
    }
}

fn extract_certificate_public_key(certificate_der: &[u8]) -> Result<Vec<u8>, AppAttestError> {
    let (_, certificate) = X509Certificate::from_der(certificate_der)
        .map_err(|_| AppAttestError::InvalidCertificate)?;
    let public_key = certificate
        .public_key()
        .subject_public_key
        .data
        .as_ref()
        .to_vec();

    if public_key.len() == 65 {
        Ok(public_key)
    } else {
        Err(AppAttestError::InvalidPublicKey)
    }
}

// DER helpers adapted from the MIT-licensed `appattest` crate. The dependency
// itself is not linked because its aws-lc-sys backend does not compile for this
// Cloudflare Workers wasm target.
fn der_read_len(buf: &[u8], pos: usize) -> Option<(usize, usize)> {
    let first = *buf.get(pos)?;
    if first < 0x80 {
        return Some((first as usize, 1));
    }

    let len_bytes = (first & 0x7f) as usize;
    let len_end = pos.checked_add(1)?.checked_add(len_bytes)?;
    if len_bytes == 0 || len_bytes > 4 || len_end > buf.len() {
        return None;
    }

    let mut len = 0usize;
    for index in 0..len_bytes {
        len = (len << 8) | (*buf.get(pos + 1 + index)? as usize);
    }
    Some((len, 1 + len_bytes))
}

fn der_unwrap_tag(buf: &[u8], expected_tag: u8) -> Option<&[u8]> {
    if buf.first()? != &expected_tag {
        return None;
    }

    let (len, consumed) = der_read_len(buf, 1)?;
    let start = 1usize.checked_add(consumed)?;
    let end = start.checked_add(len)?;
    buf.get(start..end)
}

fn der_find_extension<'a>(cert_der: &'a [u8], target_oid_bytes: &[u8]) -> Option<&'a [u8]> {
    let cert_seq = der_unwrap_tag(cert_der, 0x30)?;
    let tbs_seq = der_unwrap_tag(cert_seq, 0x30)?;

    let mut pos = 0;
    while pos < tbs_seq.len() {
        let tag = *tbs_seq.get(pos)?;
        let (len, consumed) = der_read_len(tbs_seq, pos + 1)?;
        let value_start = pos.checked_add(1)?.checked_add(consumed)?;
        let value_end = value_start.checked_add(len)?;
        let value = tbs_seq.get(value_start..value_end)?;

        if tag == 0xa3 {
            let extensions_seq = der_unwrap_tag(value, 0x30)?;
            return der_scan_extensions(extensions_seq, target_oid_bytes);
        }

        pos = value_end;
    }

    None
}

fn der_scan_extensions<'a>(extensions: &'a [u8], target_oid_bytes: &[u8]) -> Option<&'a [u8]> {
    let mut pos = 0;
    while pos < extensions.len() {
        let extension_seq = der_unwrap_tag(&extensions[pos..], 0x30)?;
        let (len, consumed) = der_read_len(extensions, pos + 1)?;
        let extension_end = pos
            .checked_add(1)?
            .checked_add(consumed)?
            .checked_add(len)?;
        if extension_end > extensions.len() {
            return None;
        }

        let (oid_len, oid_consumed) = der_read_len(extension_seq, 1)?;
        let oid_start = 1usize.checked_add(oid_consumed)?;
        let oid_end = oid_start.checked_add(oid_len)?;
        let oid_bytes = extension_seq.get(oid_start..oid_end)?;
        if extension_seq.first() == Some(&0x06) && oid_bytes == target_oid_bytes {
            let rest = extension_seq.get(oid_end..)?;
            let value_start = if rest.first() == Some(&0x01) {
                let (bool_len, bool_consumed) = der_read_len(rest, 1)?;
                1usize.checked_add(bool_consumed)?.checked_add(bool_len)?
            } else {
                0
            };
            return der_unwrap_tag(rest.get(value_start..)?, 0x04);
        }

        pos = extension_end;
    }

    None
}

fn extract_nonce_from_cert(certificate_der: &[u8]) -> Result<[u8; 32], AppAttestError> {
    const CRED_CERT_OID: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x08, 0x02];

    let extension_value =
        der_find_extension(certificate_der, CRED_CERT_OID).ok_or(AppAttestError::InvalidNonce)?;
    let sequence = der_unwrap_tag(extension_value, 0x30).ok_or(AppAttestError::InvalidNonce)?;
    let context = der_unwrap_tag(sequence, 0xa1).ok_or(AppAttestError::InvalidNonce)?;
    let nonce = der_unwrap_tag(context, 0x04).ok_or(AppAttestError::InvalidNonce)?;

    nonce.try_into().map_err(|_| AppAttestError::InvalidNonce)
}

fn pem_to_der(pem: &[u8]) -> Result<Vec<u8>, AppAttestError> {
    let pem = std::str::from_utf8(pem).map_err(|_| AppAttestError::InvalidCertificate)?;
    let base64_start = pem
        .find("-----BEGIN CERTIFICATE-----")
        .ok_or(AppAttestError::InvalidCertificate)?
        + "-----BEGIN CERTIFICATE-----".len();
    let base64_end = pem
        .find("-----END CERTIFICATE-----")
        .ok_or(AppAttestError::InvalidCertificate)?;
    let body: String = pem[base64_start..base64_end]
        .chars()
        .filter(|char| !char.is_whitespace())
        .collect();

    general_purpose::STANDARD
        .decode(body)
        .map_err(|_| AppAttestError::InvalidCertificate)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn challenge_hash_hashes_plain_challenge() {
        assert_eq!(
            challenge_hash("opencast"),
            "aedc5b582978f6344f9b781f0e4f092f77f409dd34fe9a13f68efc15191c526d"
        );
    }

    #[test]
    fn request_hash_binds_method_path_and_payload() {
        let left = request_client_data_hash("POST", "/v1/secure/hello", "hello world");
        let right = request_client_data_hash("POST", "/v1/secure/hello", "goodbye world");

        assert_ne!(left, right);
        assert_eq!(
            hex::encode(left),
            "ccb815d6ea147edd6476b79589162789924e74220cfe95c0adadf89ac4a45d7b"
        );
    }

    #[test]
    fn canonical_key_id_normalizes_standard_and_urlsafe_spellings() {
        let bytes = [251_u8; 32];
        let standard = general_purpose::STANDARD.encode(bytes);
        let urlsafe = general_purpose::URL_SAFE_NO_PAD.encode(bytes);

        assert_eq!(canonical_key_id(&standard).unwrap(), standard);
        assert_eq!(canonical_key_id(&urlsafe).unwrap(), standard);
    }

    #[test]
    fn authenticator_data_reads_counter() {
        let mut bytes = [0u8; AUTHENTICATOR_DATA_LEN];
        BigEndian::write_u32(&mut bytes[33..37], 7);

        let data = AuthenticatorData::new(&bytes).unwrap();

        assert_eq!(data.counter, 7);
    }

    #[test]
    fn authenticator_data_reads_valid_credential_id_length() {
        let mut bytes = [0u8; 87];
        BigEndian::write_u16(&mut bytes[53..55], 32);
        for index in 0..32 {
            bytes[55 + index] = index as u8;
        }

        let data = AuthenticatorData::new(&bytes).unwrap();

        assert_eq!(data.credential_id, Some(&bytes[55..87]));
    }

    #[test]
    fn authenticator_data_rejects_non_32_byte_credential_id_length() {
        let mut bytes = [0u8; 87];
        BigEndian::write_u16(&mut bytes[53..55], 31);

        assert!(matches!(
            AuthenticatorData::new(&bytes),
            Err(AppAttestError::InvalidCredentialId)
        ));
    }

    #[test]
    fn der_scan_extensions_rejects_impossible_critical_boolean_length() {
        let extensions = [0x30, 0x06, 0x06, 0x01, 0x2a, 0x01, 0x04, 0x00];

        assert_eq!(der_scan_extensions(&extensions, &[0x2a]), None);
    }

    #[test]
    fn attestation_rejects_indefinite_length_map() {
        assert!(matches!(
            Attestation::from_cbor(&[0xbf, 0xff]),
            Err(AppAttestError::InvalidAttestationFormat)
        ));
    }

    #[test]
    fn attestation_statement_rejects_indefinite_length_certificate_array() {
        let cbor = [0xa1, 0x63, b'x', b'5', b'c', 0x9f, 0xff];
        let mut decoder = minicbor::Decoder::new(&cbor);

        assert!(matches!(
            parse_attestation_statement(&mut decoder),
            Err(AppAttestError::InvalidAttestationFormat)
        ));
    }

    #[test]
    fn assertion_rejects_indefinite_length_map() {
        assert!(matches!(
            Assertion::from_cbor(&[0xbf, 0xff]),
            Err(AppAttestError::InvalidAssertionFormat)
        ));
    }

    #[test]
    fn issuer_extension_values_require_ca_capability() {
        // The checked-in App Attest fixture covers real valid and tampered chains,
        // but not a separately signed non-CA issuer chain.
        assert!(issuer_extension_values_allow_cert_signing(true, Some(true)));
        assert!(issuer_extension_values_allow_cert_signing(true, None));
        assert!(!issuer_extension_values_allow_cert_signing(
            false,
            Some(true)
        ));
        assert!(!issuer_extension_values_allow_cert_signing(
            true,
            Some(false)
        ));
    }
}
