//! Bounded offline parity probe using the actual serving receipt tokenizer.
use std::io::{self, Read};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut source = String::new();
    io::stdin()
        .take(16 * 1024 * 1024)
        .read_to_string(&mut source)?;
    let text: Vec<String> = serde_json::from_str(&source)?;
    let tokens: Vec<_> = text
        .iter()
        .map(|s| opencast_ad_analysis_worker::promo_v3::normalized_receipt_tokens(s))
        .collect();
    println!(
        "{}",
        serde_json::json!({"unicode_version":char::UNICODE_VERSION, "tokens":tokens})
    );
    Ok(())
}
