use opencast_model_gateway_worker::manifest_signature::{
    sign_manifest_bytes, write_manifest_signature,
};
use std::{env, fs, path::PathBuf, process};

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    match run(&args) {
        Ok(()) => {}
        Err(error) => {
            eprintln!("sign_manifest: {error}");
            process::exit(1);
        }
    }
}

fn run(args: &[String]) -> Result<(), String> {
    let input = PathBuf::from(required(args, "--input")?);
    let output = PathBuf::from(required(args, "--output")?);
    let key_id = required(args, "--signature-key-id")?;
    let signing_key_hex = env::var("OPENCAST_MODEL_MANIFEST_SIGNING_KEY_HEX")
        .map_err(|_| "missing OPENCAST_MODEL_MANIFEST_SIGNING_KEY_HEX".to_string())?;

    let manifest_bytes =
        fs::read(&input).map_err(|error| format!("failed to read {}: {error}", input.display()))?;
    let signature = sign_manifest_bytes(&manifest_bytes, &key_id, &signing_key_hex)?;
    write_manifest_signature(&output, &signature)
        .map_err(|error| format!("failed to write {}: {error}", output.display()))
}

fn required(args: &[String], flag: &str) -> Result<String, String> {
    optional(args, flag).ok_or_else(|| format!("missing required flag {flag}"))
}

fn optional(args: &[String], flag: &str) -> Option<String> {
    args.windows(2)
        .find(|window| window[0] == flag)
        .map(|window| window[1].clone())
}
