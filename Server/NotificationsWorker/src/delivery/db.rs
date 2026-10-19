use worker::{Env, Result};

pub fn now() -> i64 {
    (worker::Date::now().as_millis() / 1000) as i64
}
pub fn lane(env: &Env) -> String {
    env.var("NOTIFICATION_ENVIRONMENT")
        .map(|v| v.to_string())
        .unwrap_or_default()
}
pub fn id() -> String {
    // worker's crypto wrapper exposes random bytes, not UUID. Preserve RFC 4122.
    let mut bytes = [0u8; 16];
    getrandom_bytes(&mut bytes);
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    let h = hex::encode(bytes);
    format!(
        "{}-{}-{}-{}-{}",
        &h[..8],
        &h[8..12],
        &h[12..16],
        &h[16..20],
        &h[20..]
    )
}
fn getrandom_bytes(bytes: &mut [u8]) {
    // Cryptographic randomness supplied by the existing shared core helper.
    let token = crate::random::random_urlsafe_token(32).expect("Workers crypto");
    use sha2::{Digest, Sha256};
    bytes.copy_from_slice(&Sha256::digest(token.as_bytes())[..bytes.len()]);
}
/// New and returning clients use the queued engine. Existing authority and
/// history are never rewritten by registration or full-set subscription sync.
pub fn ensure_feed(
    _db: &crate::database::Authority,
    url: &str,
    now: i64,
) -> Result<crate::database::slice_c::SubscriptionWrite> {
    Ok(crate::database::slice_c::SubscriptionWrite::EnsureFeed {
        url: url.into(),
        now,
    })
}
