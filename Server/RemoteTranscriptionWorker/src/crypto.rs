//! AES-256-GCM envelope for the enclosure URL at rest inside the job DO. The
//! ciphertext is cleared as soon as backend staging finishes; durable
//! diagnostics only ever carry the keyed URL hash.

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use base64::Engine;

pub const URL_ENCRYPTION_KEY_SECRET: &str = "URL_ENCRYPTION_KEY";
/// Development-lane fallback so local/dev flows work before secrets exist.
/// config.rs guarantees non-development lanes never rely on it (they must set
/// the secret; see resolve_key).
const DEVELOPMENT_FALLBACK_KEY: &[u8; 32] = b"opencast-dev-url-encryption-key!";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CryptoError {
    InvalidKey,
    EncryptFailed,
    DecryptFailed,
}

pub fn resolve_key(
    secret_hex: Option<&str>,
    is_development_lane: bool,
) -> Result<[u8; 32], CryptoError> {
    if let Some(secret_hex) = secret_hex {
        let bytes = hex::decode(secret_hex.trim()).map_err(|_| CryptoError::InvalidKey)?;
        return bytes.try_into().map_err(|_| CryptoError::InvalidKey);
    }
    if is_development_lane {
        return Ok(*DEVELOPMENT_FALLBACK_KEY);
    }
    Err(CryptoError::InvalidKey)
}

pub fn encrypt_string(
    plaintext: &str,
    key: &[u8; 32],
    nonce_bytes: &[u8; 12],
) -> Result<String, CryptoError> {
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| CryptoError::InvalidKey)?;
    let nonce = Nonce::from(*nonce_bytes);
    let ciphertext = cipher
        .encrypt(&nonce, plaintext.as_bytes())
        .map_err(|_| CryptoError::EncryptFailed)?;
    let mut combined = Vec::with_capacity(12 + ciphertext.len());
    combined.extend_from_slice(nonce_bytes);
    combined.extend_from_slice(&ciphertext);
    Ok(base64::engine::general_purpose::STANDARD.encode(combined))
}

pub fn decrypt_string(encoded: &str, key: &[u8; 32]) -> Result<String, CryptoError> {
    let combined = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .map_err(|_| CryptoError::DecryptFailed)?;
    if combined.len() < 13 {
        return Err(CryptoError::DecryptFailed);
    }
    let (nonce_bytes, ciphertext) = combined.split_at(12);
    let nonce_bytes: &[u8; 12] = nonce_bytes
        .try_into()
        .map_err(|_| CryptoError::DecryptFailed)?;
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| CryptoError::InvalidKey)?;
    let nonce = Nonce::from(*nonce_bytes);
    let plaintext = cipher
        .decrypt(&nonce, ciphertext)
        .map_err(|_| CryptoError::DecryptFailed)?;
    String::from_utf8(plaintext).map_err(|_| CryptoError::DecryptFailed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrips_and_rejects_wrong_key() {
        let key = resolve_key(None, true).expect("dev fallback key");
        let nonce = [7u8; 12];
        let encrypted = encrypt_string("https://example.com/feed.mp3?tok=s3cret", &key, &nonce)
            .expect("encrypts");
        assert_eq!(
            decrypt_string(&encrypted, &key).expect("decrypts"),
            "https://example.com/feed.mp3?tok=s3cret"
        );
        let other = resolve_key(Some(&"ab".repeat(32)), false).expect("hex key");
        assert_eq!(
            decrypt_string(&encrypted, &other),
            Err(CryptoError::DecryptFailed)
        );
    }

    #[test]
    fn key_resolution_fails_closed_outside_development() {
        assert_eq!(resolve_key(None, false), Err(CryptoError::InvalidKey));
        assert!(resolve_key(Some("zz"), false).is_err());
        assert!(resolve_key(Some(&"ab".repeat(32)), false).is_ok());
    }
}
