use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    fs,
    io::{self, Read},
    path::{Path, PathBuf},
};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RemoteModelManifest {
    pub schema_version: u8,
    pub generated_at: String,
    pub models: Vec<RemoteModel>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RemoteModel {
    pub model_id: String,
    pub version: String,
    pub model_folder: String,
    pub tokenizer_folder: String,
    pub total_byte_count: u64,
    pub tree_sha256: String,
    pub files: Vec<RemoteModelFile>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RemoteModelFile {
    pub path: String,
    pub url_path: String,
    pub byte_count: u64,
    pub sha256: String,
    pub content_type: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManifestInput {
    pub model_id: String,
    pub version: String,
    pub generated_at: String,
    pub model_folder: PathBuf,
    pub tokenizer_folder: PathBuf,
}

pub fn generate_manifest(input: &ManifestInput) -> io::Result<RemoteModelManifest> {
    let mut files = Vec::new();
    append_component_files(
        &mut files,
        "model",
        &input.model_folder,
        &input.model_id,
        &input.version,
    )?;
    append_component_files(
        &mut files,
        "tokenizer",
        &input.tokenizer_folder,
        &input.model_id,
        &input.version,
    )?;
    files.sort_by(|lhs, rhs| lhs.path.cmp(&rhs.path));

    if files.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "model and tokenizer folders did not contain files",
        ));
    }

    let total_byte_count = files.iter().map(|file| file.byte_count).sum();
    let tree_sha256 = tree_hash(&files);

    Ok(RemoteModelManifest {
        schema_version: 1,
        generated_at: input.generated_at.clone(),
        models: vec![RemoteModel {
            model_id: input.model_id.clone(),
            version: input.version.clone(),
            model_folder: "model".to_string(),
            tokenizer_folder: "tokenizer".to_string(),
            total_byte_count,
            tree_sha256,
            files,
        }],
    })
}

/// Reads a model manifest from JSON on disk.
///
/// # Errors
///
/// Returns an error when the file cannot be read or the JSON does not match the
/// manifest schema.
pub fn read_manifest(path: &Path) -> io::Result<RemoteModelManifest> {
    let data = fs::read(path)?;
    serde_json::from_slice(&data).map_err(io::Error::other)
}

/// Combines one or more single- or multi-model manifests into a stable manifest.
///
/// # Errors
///
/// Returns an error when no input manifests are supplied, an input uses an
/// unsupported schema version, duplicate model releases are present, or the
/// merged output would contain no models.
pub fn merge_manifests(
    generated_at: String,
    manifests: Vec<RemoteModelManifest>,
) -> io::Result<RemoteModelManifest> {
    if manifests.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "at least one manifest input is required",
        ));
    }

    let mut keys = HashSet::new();
    let mut models = Vec::new();
    for manifest in manifests {
        if manifest.schema_version != 1 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("unsupported schema version {}", manifest.schema_version),
            ));
        }

        for model in manifest.models {
            let key = (model.model_id.clone(), model.version.clone());
            if !keys.insert(key) {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!(
                        "duplicate model release: {} {}",
                        model.model_id, model.version
                    ),
                ));
            }
            models.push(model);
        }
    }

    if models.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "merged manifest must include at least one model",
        ));
    }

    models.sort_by(|lhs, rhs| {
        lhs.model_id
            .cmp(&rhs.model_id)
            .then_with(|| lhs.version.cmp(&rhs.version))
    });

    Ok(RemoteModelManifest {
        schema_version: 1,
        generated_at,
        models,
    })
}

pub fn manifest_json_bytes(manifest: &RemoteModelManifest) -> io::Result<Vec<u8>> {
    serde_json::to_vec_pretty(manifest).map_err(io::Error::other)
}

pub fn write_manifest_bytes(path: &Path, data: &[u8]) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(path, data)?;
    Ok(())
}

fn append_component_files(
    files: &mut Vec<RemoteModelFile>,
    component: &str,
    folder: &Path,
    model_id: &str,
    version: &str,
) -> io::Result<()> {
    if !folder.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("component folder does not exist: {}", folder.display()),
        ));
    }

    for path in component_files(folder)? {
        let relative_path = relative_manifest_path(folder, &path)?;
        let manifest_path = format!("{component}/{relative_path}");
        let byte_count = fs::metadata(&path)?.len();
        files.push(RemoteModelFile {
            path: manifest_path.clone(),
            url_path: format!("/v1/models/assets/{model_id}/{version}/{manifest_path}"),
            byte_count,
            sha256: file_sha256(&path)?,
            content_type: content_type_for_path(&relative_path).to_string(),
        });
    }

    Ok(())
}

fn component_files(folder: &Path) -> io::Result<Vec<PathBuf>> {
    let mut stack = vec![folder.to_path_buf()];
    let mut files = Vec::new();

    while let Some(path) = stack.pop() {
        for entry in fs::read_dir(path)? {
            let entry = entry?;
            let path = entry.path();
            let metadata = entry.metadata()?;
            if metadata.is_dir() {
                stack.push(path);
            } else if metadata.is_file() {
                files.push(path);
            }
        }
    }

    files.sort();
    Ok(files)
}

fn relative_manifest_path(base: &Path, path: &Path) -> io::Result<String> {
    let relative = path.strip_prefix(base).map_err(io::Error::other)?;
    let mut parts = Vec::new();
    for component in relative.components() {
        let Some(part) = component.as_os_str().to_str() else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "paths must be valid UTF-8",
            ));
        };
        if part.is_empty() || part == "." || part == ".." {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "paths must not contain empty, dot, or dot-dot segments",
            ));
        }
        parts.push(part);
    }
    Ok(parts.join("/"))
}

fn file_sha256(path: &Path) -> io::Result<String> {
    let mut file = fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0; 128 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hex::encode(hasher.finalize()))
}

fn tree_hash(files: &[RemoteModelFile]) -> String {
    let mut hasher = Sha256::new();
    for file in files {
        hasher.update(file.path.as_bytes());
        hasher.update([0]);
        hasher.update(file.sha256.as_bytes());
        hasher.update([0]);
        hasher.update(file.byte_count.to_string().as_bytes());
        hasher.update([10]);
    }
    hex::encode(hasher.finalize())
}

fn content_type_for_path(path: &str) -> &'static str {
    if path.to_ascii_lowercase().ends_with(".json") {
        "application/json; charset=utf-8"
    } else {
        "application/octet-stream"
    }
}
