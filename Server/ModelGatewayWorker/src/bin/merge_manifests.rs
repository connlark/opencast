use opencast_model_gateway_worker::{
    manifest::{manifest_json_bytes, merge_manifests, read_manifest, write_manifest_bytes},
    manifest_signature::{sign_manifest_bytes, write_manifest_signature},
};
use std::{env, path::PathBuf, process};

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    match run(&args) {
        Ok(()) => {}
        Err(error) => {
            eprintln!("merge_manifests: {error}");
            process::exit(1);
        }
    }
}

fn run(args: &[String]) -> Result<(), String> {
    let inputs = values(args, "--input");
    if inputs.is_empty() {
        return Err("missing required flag --input".to_string());
    }

    let generated_at = required(args, "--generated-at")?;
    let output = PathBuf::from(required(args, "--output")?);
    let signature_output = optional(args, "--signature-output").map(PathBuf::from);

    let manifests = inputs
        .iter()
        .map(|path| read_manifest(&PathBuf::from(path)).map_err(|error| error.to_string()))
        .collect::<Result<Vec<_>, _>>()?;
    let manifest = merge_manifests(generated_at, manifests).map_err(|error| error.to_string())?;
    let manifest_bytes = manifest_json_bytes(&manifest).map_err(|error| error.to_string())?;
    write_manifest_bytes(&output, &manifest_bytes).map_err(|error| error.to_string())?;

    if let Some(signature_output) = signature_output {
        let key_id = required(args, "--signature-key-id")?;
        let signing_key_hex = env::var("OPENCAST_MODEL_MANIFEST_SIGNING_KEY_HEX")
            .map_err(|_| "missing OPENCAST_MODEL_MANIFEST_SIGNING_KEY_HEX".to_string())?;
        let signature = sign_manifest_bytes(&manifest_bytes, &key_id, &signing_key_hex)?;
        write_manifest_signature(&signature_output, &signature)
            .map_err(|error| error.to_string())?;
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

fn values(args: &[String], flag: &str) -> Vec<String> {
    args.windows(2)
        .filter(|window| window[0] == flag)
        .map(|window| window[1].clone())
        .collect()
}
