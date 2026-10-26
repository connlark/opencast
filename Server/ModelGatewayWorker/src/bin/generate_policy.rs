//! Generates the analysis policy bundle from the analysis workers' constants,
//! optionally signs it, and writes the app's baked copy and test fixtures.

use opencast_model_gateway_worker::{
    analysis_policy::{bundle_json_bytes, generate, sign_policy_bytes, GenerationInputs},
    manifest::write_manifest_bytes,
    manifest_signature::write_manifest_signature,
    policy_swift::{baked_source, fixtures_source, test_fixtures},
};
use std::{env, path::PathBuf, process};

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    if let Err(error) = run(&args) {
        eprintln!("generate_policy: {error}");
        process::exit(1);
    }
}

fn run(args: &[String]) -> Result<(), String> {
    let inputs = GenerationInputs {
        bundle_version: parse(&required(args, "--bundle-version")?, "--bundle-version")?,
        generated_at: required(args, "--generated-at")?,
        min_app_build: parse(&required(args, "--min-app-build")?, "--min-app-build")?,
    };
    let output = PathBuf::from(required(args, "--output")?);
    let bundle = generate(&inputs)?;
    let bytes = bundle_json_bytes(&bundle)?;
    write_manifest_bytes(&output, &bytes).map_err(|error| error.to_string())?;

    if let Some(signature_output) = optional(args, "--signature-output") {
        let key_id = required(args, "--signature-key-id")?;
        let signing_key_hex = env::var("OPENCAST_MODEL_MANIFEST_SIGNING_KEY_HEX")
            .map_err(|_| "missing OPENCAST_MODEL_MANIFEST_SIGNING_KEY_HEX".to_string())?;
        let signature = sign_policy_bytes(&bytes, &key_id, &signing_key_hex)?;
        write_manifest_signature(&PathBuf::from(signature_output), &signature)
            .map_err(|error| error.to_string())?;
    }
    if let Some(path) = optional(args, "--swift-baked-output") {
        let source = baked_source(&bytes, bundle.bundle_version)?;
        write_manifest_bytes(&PathBuf::from(path), source.as_bytes())
            .map_err(|error| error.to_string())?;
    }
    if let Some(path) = optional(args, "--swift-test-fixtures-output") {
        let source = fixtures_source(&test_fixtures(&bundle)?)?;
        write_manifest_bytes(&PathBuf::from(path), source.as_bytes())
            .map_err(|error| error.to_string())?;
    }
    Ok(())
}

fn parse<T: std::str::FromStr>(value: &str, flag: &str) -> Result<T, String> {
    value
        .parse()
        .map_err(|_| format!("{flag} must be a non-negative integer"))
}

fn required(args: &[String], flag: &str) -> Result<String, String> {
    optional(args, flag).ok_or_else(|| format!("missing required flag {flag}"))
}

fn optional(args: &[String], flag: &str) -> Option<String> {
    args.windows(2)
        .find(|window| window[0] == flag)
        .map(|window| window[1].clone())
}
