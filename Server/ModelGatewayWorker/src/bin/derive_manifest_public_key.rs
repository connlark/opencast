use opencast_model_gateway_worker::manifest_signature::public_key_hex_from_signing_key_hex;
use std::{env, fs, path::PathBuf, process};

fn main() {
    match run() {
        Ok(public_key_hex) => println!("{public_key_hex}"),
        Err(error) => {
            eprintln!("derive_manifest_public_key: {error}");
            process::exit(1);
        }
    }
}

fn run() -> Result<String, String> {
    let key_file = PathBuf::from(
        env::args()
            .nth(1)
            .ok_or_else(|| "missing signing key file path".to_string())?,
    );
    let signing_key_hex = fs::read_to_string(&key_file)
        .map_err(|error| format!("failed to read {}: {error}", key_file.display()))?;
    public_key_hex_from_signing_key_hex(&signing_key_hex)
}
