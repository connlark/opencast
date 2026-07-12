use opencast_model_gateway_worker::{
    manifest::{generate_manifest, manifest_json_bytes, write_manifest_bytes, ManifestInput},
    manifest_signature::{sign_manifest_bytes, write_manifest_signature},
};
use std::{env, path::PathBuf, process};

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    match run(&args) {
        Ok(()) => {}
        Err(error) => {
            eprintln!("generate_manifest: {error}");
            process::exit(1);
        }
    }
}

fn run(args: &[String]) -> Result<(), String> {
    let input = ManifestInput {
        model_id: required(args, "--model-id")?,
        version: required(args, "--version")?,
        generated_at: required(args, "--generated-at")?,
        model_folder: PathBuf::from(required(args, "--model-folder")?),
        tokenizer_folder: PathBuf::from(required(args, "--tokenizer-folder")?),
    };
    let output = PathBuf::from(required(args, "--output")?);
    let current_output = optional(args, "--current-output").map(PathBuf::from);
    let signature_output = optional(args, "--signature-output").map(PathBuf::from);
    let current_signature_output = optional(args, "--current-signature-output").map(PathBuf::from);

    let manifest = generate_manifest(&input).map_err(|error| error.to_string())?;
    let manifest_bytes = manifest_json_bytes(&manifest).map_err(|error| error.to_string())?;
    write_manifest_bytes(&output, &manifest_bytes).map_err(|error| error.to_string())?;
    if let Some(current_output) = current_output {
        write_manifest_bytes(&current_output, &manifest_bytes)
            .map_err(|error| error.to_string())?;
    }

    if signature_output.is_some() || current_signature_output.is_some() {
        let key_id = required(args, "--signature-key-id")?;
        let signing_key_hex = env::var("OPENCAST_MODEL_MANIFEST_SIGNING_KEY_HEX")
            .map_err(|_| "missing OPENCAST_MODEL_MANIFEST_SIGNING_KEY_HEX".to_string())?;
        let signature = sign_manifest_bytes(&manifest_bytes, &key_id, &signing_key_hex)?;
        if let Some(signature_output) = signature_output {
            write_manifest_signature(&signature_output, &signature)
                .map_err(|error| error.to_string())?;
        }
        if let Some(current_signature_output) = current_signature_output {
            write_manifest_signature(&current_signature_output, &signature)
                .map_err(|error| error.to_string())?;
        }
    }

    Ok(())
}

fn required(args: &[String], flag: &str) -> Result<String, String> {
    optional(args, flag).ok_or_else(|| format!("missing required flag {flag}"))
}

fn optional(args: &[String], flag: &str) -> Option<String> {
    args.windows(2)
        .find(|window| window[0] == flag)
        .map(|window| window[1].clone())
}
