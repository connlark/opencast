//! Embeds the highest-numbered checked-in analysis policy bundle. The worker
//! reads its trial model entries from this copy, never from a client, so a
//! bundle publish that changes a trial entry is followed by a deploy.

use std::{env, fs, path::Path};

const MANIFEST_DIR: &str = "../ModelGatewayWorker/manifests/analysis-policy";

fn main() {
    println!("cargo:rerun-if-changed={MANIFEST_DIR}");
    let (version, path) = fs::read_dir(MANIFEST_DIR)
        .unwrap_or_else(|error| panic!("read {MANIFEST_DIR}: {error}"))
        .filter_map(|entry| {
            let path = entry.ok()?.path();
            let name = path.file_name()?.to_str()?;
            let version = name.strip_prefix('v')?.strip_suffix(".json")?;
            if version.is_empty() || !version.bytes().all(|byte| byte.is_ascii_digit()) {
                return None;
            }
            Some((version.parse::<u64>().ok()?, path))
        })
        .max_by_key(|(version, _)| *version)
        .unwrap_or_else(|| panic!("no vN.json bundle in {MANIFEST_DIR}"));
    let out = Path::new(&env::var("OUT_DIR").expect("OUT_DIR")).join("analysis-policy.json");
    fs::copy(&path, &out).unwrap_or_else(|error| panic!("copy {}: {error}", path.display()));
    println!("cargo:rustc-env=TRIAL_EMBEDDED_BUNDLE_FILE=v{version}.json");
}
