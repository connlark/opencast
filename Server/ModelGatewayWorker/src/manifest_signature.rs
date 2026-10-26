use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use serde::{Deserialize, Serialize};
use std::{fs, io, path::Path};
use zeroize::Zeroizing;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ManifestSignature {
    pub schema_version: u8,
    pub algorithm: String,
    pub key_id: String,
    /// Policy envelopes name the exact document they sign, so a client can
    /// fetch that document's immutable copy; model manifests omit both.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bundle_version: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sha256: Option<String>,
    pub signature: String,
}

pub fn sign_manifest_bytes(
    manifest_bytes: &[u8],
    key_id: &str,
    signing_key_hex: &str,
) -> Result<ManifestSignature, String> {
    let signing_key = signing_key_from_hex(signing_key_hex)?;
    let signature = signing_key.sign(manifest_bytes);
    Ok(ManifestSignature {
        schema_version: 1,
        algorithm: "ed25519".to_string(),
        // Advisory metadata only. Clients must verify with a pinned public key,
        // not trust or select a key solely from this string.
        key_id: key_id.to_string(),
        bundle_version: None,
        sha256: None,
        signature: hex::encode(signature.to_bytes()),
    })
}

/// Derives the Ed25519 public key hex string from a 32-byte signing seed.
///
/// # Errors
///
/// Returns an error when the input is not valid hex or does not decode to
/// exactly 32 bytes.
pub fn public_key_hex_from_signing_key_hex(signing_key_hex: &str) -> Result<String, String> {
    let signing_key = signing_key_from_hex(signing_key_hex)?;
    Ok(hex::encode(signing_key.verifying_key().to_bytes()))
}

/// Verifies a detached signature envelope over `manifest_bytes` with a pinned
/// public key, the way the app does: schema version 1, Ed25519, the expected
/// key id, then the signature itself.
///
/// # Errors
///
/// Returns the first check that fails.
pub fn verify_manifest_bytes(
    manifest_bytes: &[u8],
    signature: &ManifestSignature,
    public_key_hex: &str,
    expected_key_id: &str,
) -> Result<(), String> {
    if signature.schema_version != 1 {
        return Err(format!(
            "unsupported signature schema version {}",
            signature.schema_version
        ));
    }
    if signature.algorithm != "ed25519" {
        return Err(format!(
            "unsupported signature algorithm {}",
            signature.algorithm
        ));
    }
    if signature.key_id != expected_key_id {
        return Err(format!(
            "signature key id {} does not match the pinned key",
            signature.key_id
        ));
    }
    let key_bytes: [u8; 32] = hex::decode(public_key_hex.trim())
        .map_err(|error| error.to_string())?
        .try_into()
        .map_err(|_| "public key must be 32 bytes".to_string())?;
    let signature_bytes: [u8; 64] = hex::decode(signature.signature.trim())
        .map_err(|error| error.to_string())?
        .try_into()
        .map_err(|_| "signature must be 64 bytes".to_string())?;
    let key = VerifyingKey::from_bytes(&key_bytes).map_err(|error| error.to_string())?;
    key.verify_strict(manifest_bytes, &Signature::from_bytes(&signature_bytes))
        .map_err(|_| "signature did not verify".to_string())
}

pub fn write_manifest_signature(path: &Path, signature: &ManifestSignature) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let data = serde_json::to_vec_pretty(signature).map_err(io::Error::other)?;
    fs::write(path, data)?;
    Ok(())
}

fn signing_key_from_hex(value: &str) -> Result<SigningKey, String> {
    let bytes = Zeroizing::new(hex::decode(value.trim()).map_err(|error| error.to_string())?);
    if bytes.len() != 32 {
        return Err("OPENCAST_MODEL_MANIFEST_SIGNING_KEY_HEX must be 32 bytes".to_string());
    }

    let mut key_bytes = Zeroizing::new([0_u8; 32]);
    key_bytes.copy_from_slice(&bytes);
    Ok(SigningKey::from_bytes(&key_bytes))
}
