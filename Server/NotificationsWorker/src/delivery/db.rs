use super::wire::{hash, int};
use serde_json::{json, Value};
use worker::{wasm_bindgen::JsValue, D1Database, D1PreparedStatement, Env, Result};

pub fn statement(db: &D1Database, sql: &str, args: &[Value]) -> Result<D1PreparedStatement> {
    let values: Vec<JsValue> = args
        .iter()
        .map(|v| match v {
            Value::Null => JsValue::NULL,
            Value::Bool(v) => JsValue::from_f64(i32::from(*v) as f64),
            Value::Number(v) => JsValue::from_f64(v.as_f64().unwrap_or(0.0)),
            Value::String(v) => JsValue::from_str(v),
            _ => JsValue::from_str(&v.to_string()),
        })
        .collect();
    db.prepare(sql).bind(&values)
}
pub async fn first(db: &D1Database, sql: &str, args: &[Value]) -> Result<Option<Value>> {
    statement(db, sql, args)?.first(None).await
}
pub async fn rows(db: &D1Database, sql: &str, args: &[Value]) -> Result<Vec<Value>> {
    statement(db, sql, args)?.all().await?.results()
}
pub async fn run(db: &D1Database, sql: &str, args: &[Value]) -> Result<usize> {
    Ok(statement(db, sql, args)?
        .run()
        .await?
        .meta()?
        .and_then(|m| m.changes)
        .unwrap_or(0))
}
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
pub async fn control(db: &D1Database, name: &str) -> Result<bool> {
    Ok(first(
        db,
        "SELECT enabled FROM n_control WHERE name=?1",
        &[json!(name)],
    )
    .await?
    .is_some_and(|v| int(&v, "enabled") == 1))
}
pub async fn permitted(env: &Env, db: &D1Database, name: &str) -> Result<bool> {
    let key = format!("NOTIFICATION_{}", name.to_uppercase());
    Ok(env
        .var(&key)
        .map(|v| v.to_string() != "false")
        .unwrap_or(true)
        && control(db, name).await?)
}
/// New and returning clients use the queued engine. Existing authority and
/// history are never rewritten by registration or full-set subscription sync.
pub fn ensure_feed(db: &D1Database, url: &str, now: i64) -> Result<D1PreparedStatement> {
    let feed_id = hash(&["feed-v1", url]);
    statement(db,"INSERT INTO n_feed(feed_id,canonical_url,epoch,due_at) VALUES(?1,?2,1,?3) ON CONFLICT(canonical_url) DO NOTHING",&[json!(feed_id),json!(url),json!(now)])
}
