use opencast_model_gateway_worker::{
    manifest::{generate_manifest, manifest_json_bytes, merge_manifests, ManifestInput},
    manifest_signature::{public_key_hex_from_signing_key_hex, sign_manifest_bytes},
};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::{Path, PathBuf},
};

#[test]
fn generator_emits_stable_sorted_manifest() {
    let temp = TestFolder::new("stable");
    temp.write("model/b.txt", b"bbb");
    temp.write("model/a.json", br#"{"a":true}"#);
    temp.write("tokenizer/tokenizer.json", br#"{"tok":1}"#);

    let manifest = generate_manifest(&ManifestInput {
        model_id: "model-a".to_string(),
        version: "v1".to_string(),
        generated_at: "2026-06-28T00:00:00Z".to_string(),
        model_folder: temp.path.join("model"),
        tokenizer_folder: temp.path.join("tokenizer"),
    })
    .unwrap();

    let model = &manifest.models[0];
    let paths: Vec<&str> = model.files.iter().map(|file| file.path.as_str()).collect();
    assert_eq!(
        paths,
        vec!["model/a.json", "model/b.txt", "tokenizer/tokenizer.json"]
    );
    assert_eq!(model.total_byte_count, 22);
    assert_eq!(
        model.files[0].sha256,
        hex::encode(Sha256::digest(br#"{"a":true}"#))
    );
    assert_eq!(
        model.files[0].url_path,
        "/v1/models/assets/model-a/v1/model/a.json"
    );
    assert_eq!(
        model.files[0].content_type,
        "application/json; charset=utf-8"
    );
    assert_eq!(model.files[1].content_type, "application/octet-stream");
}

#[test]
fn tree_hash_changes_when_file_content_changes() {
    let first = manifest_for_content("tree-a", b"one");
    let second = manifest_for_content("tree-b", b"two");

    assert_ne!(first.models[0].tree_sha256, second.models[0].tree_sha256);
}

#[test]
fn manifest_signature_uses_ed25519_envelope() {
    let manifest = manifest_for_content("signature", b"one");
    let bytes = manifest_json_bytes(&manifest).unwrap();
    let signing_key_hex = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60";

    let signature = sign_manifest_bytes(&bytes, "test-key", signing_key_hex).unwrap();

    assert_eq!(signature.schema_version, 1);
    assert_eq!(signature.algorithm, "ed25519");
    assert_eq!(signature.key_id, "test-key");
    assert_eq!(signature.signature.len(), 128);
}

#[test]
fn manifest_public_key_derivation_matches_rfc8032_test_vector() {
    let signing_key_hex = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60";

    let public_key_hex = public_key_hex_from_signing_key_hex(signing_key_hex).unwrap();

    assert_eq!(
        public_key_hex,
        "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
    );
}

#[test]
fn generator_treats_json_extension_case_insensitively() {
    let temp = TestFolder::new("json-case");
    temp.write("model/CONFIG.JSON", br#"{"a":true}"#);
    temp.write("tokenizer/tokenizer.json", br#"{"tok":1}"#);

    let manifest = generate_manifest(&ManifestInput {
        model_id: "model-a".to_string(),
        version: "v1".to_string(),
        generated_at: "2026-06-28T00:00:00Z".to_string(),
        model_folder: temp.path.join("model"),
        tokenizer_folder: temp.path.join("tokenizer"),
    })
    .unwrap();

    assert_eq!(
        manifest.models[0].files[0].content_type,
        "application/json; charset=utf-8"
    );
}

#[test]
fn merge_manifests_combines_models_in_stable_order() {
    let first = manifest_for_model("model-b", "v2", "merge-b", b"two");
    let second = manifest_for_model("model-a", "v1", "merge-a", b"one");

    let merged = merge_manifests("2026-07-01T00:00:00Z".to_string(), vec![first, second]).unwrap();

    assert_eq!(merged.schema_version, 1);
    assert_eq!(merged.generated_at, "2026-07-01T00:00:00Z");
    assert_eq!(merged.models.len(), 2);
    assert_eq!(merged.models[0].model_id, "model-a");
    assert_eq!(merged.models[0].version, "v1");
    assert_eq!(merged.models[1].model_id, "model-b");
    assert_eq!(merged.models[1].version, "v2");
}

#[test]
fn merge_manifests_rejects_duplicate_model_releases() {
    let first = manifest_for_model("model-a", "v1", "duplicate-a", b"one");
    let second = manifest_for_model("model-a", "v1", "duplicate-b", b"two");

    let error =
        merge_manifests("2026-07-01T00:00:00Z".to_string(), vec![first, second]).unwrap_err();

    assert_eq!(error.kind(), std::io::ErrorKind::InvalidInput);
}

#[test]
fn generator_rejects_missing_folders() {
    let temp = TestFolder::new("missing");
    let error = generate_manifest(&ManifestInput {
        model_id: "model-a".to_string(),
        version: "v1".to_string(),
        generated_at: "2026-06-28T00:00:00Z".to_string(),
        model_folder: temp.path.join("missing-model"),
        tokenizer_folder: temp.path.join("missing-tokenizer"),
    })
    .unwrap_err();

    assert_eq!(error.kind(), std::io::ErrorKind::InvalidInput);
}

fn manifest_for_content(
    name: &str,
    content: &[u8],
) -> opencast_model_gateway_worker::manifest::RemoteModelManifest {
    manifest_for_model("model-a", "v1", name, content)
}

fn manifest_for_model(
    model_id: &str,
    version: &str,
    name: &str,
    content: &[u8],
) -> opencast_model_gateway_worker::manifest::RemoteModelManifest {
    let temp = TestFolder::new(name);
    temp.write("model/file.bin", content);
    temp.write("tokenizer/tokenizer.json", br#"{}"#);

    generate_manifest(&ManifestInput {
        model_id: model_id.to_string(),
        version: version.to_string(),
        generated_at: "2026-06-28T00:00:00Z".to_string(),
        model_folder: temp.path.join("model"),
        tokenizer_folder: temp.path.join("tokenizer"),
    })
    .unwrap()
}

struct TestFolder {
    path: PathBuf,
}

impl TestFolder {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "opencast-model-gateway-tests-{name}-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        Self { path }
    }

    fn write(&self, relative: &str, bytes: &[u8]) {
        let path = self.path.join(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, bytes).unwrap();
    }
}

impl Drop for TestFolder {
    fn drop(&mut self) {
        remove_dir_all_if_exists(&self.path);
    }
}

fn remove_dir_all_if_exists(path: &Path) {
    if path.exists() {
        fs::remove_dir_all(path).unwrap();
    }
}
