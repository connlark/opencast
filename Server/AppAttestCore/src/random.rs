use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};

pub fn random_urlsafe_token(byte_count: usize) -> Result<String, getrandom::Error> {
    let mut bytes = vec![0u8; byte_count];
    getrandom::getrandom(&mut bytes)?;
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}
