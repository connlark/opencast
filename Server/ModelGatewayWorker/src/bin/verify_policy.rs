//! Re-verifies a signed analysis policy bundle the way the app will: the
//! detached Ed25519 signature against the pinned key, the JSON schema (with
//! the app's numeric bounds) and the relational rules. Also reports whether
//! the bytes still equal what the generator produces from today's constants.

use opencast_model_gateway_worker::{
    analysis_policy::{
        bundle_json_bytes, check_bundle, generate, parse_bundle, verify_policy_bytes,
        GenerationInputs, PINNED_PUBLIC_KEY_HEX, SIGNATURE_KEY_ID,
    },
    manifest_signature::ManifestSignature,
    policy_schema,
};
use sha2::{Digest, Sha256};
use std::{env, fs, path::PathBuf, process};

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    if let Err(error) = run(&args) {
        eprintln!("verify_policy: {error}");
        process::exit(1);
    }
}

fn run(args: &[String]) -> Result<(), String> {
    let input = PathBuf::from(required(args, "--input")?);
    let signature_path = PathBuf::from(required(args, "--signature")?);
    let public_key_hex =
        optional(args, "--public-key-hex").unwrap_or_else(|| PINNED_PUBLIC_KEY_HEX.to_string());
    let key_id = optional(args, "--key-id").unwrap_or_else(|| SIGNATURE_KEY_ID.to_string());
    let schema_path = optional(args, "--schema").map_or_else(
        || {
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("manifests")
                .join("analysis-policy.schema.json")
        },
        PathBuf::from,
    );

    let bytes = read(&input)?;
    let signature: ManifestSignature = serde_json::from_slice(&read(&signature_path)?)
        .map_err(|error| format!("signature envelope: {error}"))?;
    verify_policy_bytes(&bytes, &signature, &public_key_hex, &key_id)?;
    println!("signature: ok ({key_id})");

    let schema: serde_json::Value =
        serde_json::from_slice(&read(&schema_path)?).map_err(|error| format!("schema: {error}"))?;
    let instance: serde_json::Value =
        serde_json::from_slice(&bytes).map_err(|error| format!("bundle: {error}"))?;
    policy_schema::validate(&schema, &instance).map_err(|errors| errors.join("\n"))?;
    println!("schema: ok");

    let bundle = parse_bundle(&bytes)?;
    check_bundle(&bundle)?;
    println!("relational rules: ok");

    let regenerated = bundle_json_bytes(&generate(&GenerationInputs {
        bundle_version: bundle.bundle_version,
        generated_at: bundle.generated_at.clone(),
        min_app_build: bundle.min_app_build,
    })?)?;
    println!(
        "bundle_version {} min_app_build {} bytes {} sha256 {}",
        bundle.bundle_version,
        bundle.min_app_build,
        bytes.len(),
        hex::encode(Sha256::digest(&bytes))
    );
    println!(
        "matches today's generator output: {}",
        if regenerated == bytes { "yes" } else { "no" }
    );
    Ok(())
}

fn read(path: &PathBuf) -> Result<Vec<u8>, String> {
    fs::read(path).map_err(|error| format!("failed to read {}: {error}", path.display()))
}

fn required(args: &[String], flag: &str) -> Result<String, String> {
    optional(args, flag).ok_or_else(|| format!("missing required flag {flag}"))
}

fn optional(args: &[String], flag: &str) -> Option<String> {
    args.windows(2)
        .find(|window| window[0] == flag)
        .map(|window| window[1].clone())
}
