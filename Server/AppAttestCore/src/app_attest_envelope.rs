//! The shared post-crypto App Attest request tier: read the authenticated
//! envelope under a byte cap, look up the registered key, verify the
//! assertion against the exact method/path/payload binding, and advance the
//! sign counter. One copy for every worker; each projects what it needs from
//! `AuthenticatedPayload`.

pub mod slice_c;
use futures_util::StreamExt;
use serde::Deserialize;
use worker::{D1Database, Request, Result};

use crate::app_attest::{canonical_key_id, request_client_data_hash, verify_assertion};
use crate::app_attest_storage as storage;

#[derive(Deserialize)]
struct AuthenticatedEnvelope {
    install_id: Option<String>,
    key_id: Option<String>,
    payload: Option<String>,
    assertion: Option<String>,
}

pub struct AuthenticatedPayload {
    pub install_id: String,
    pub key_id: String,
    pub payload: String,
}

pub struct AuthFailure {
    pub status: u16,
    pub code: &'static str,
    /// Populated only for failures past key lookup, so callers that record
    /// per-install attempt telemetry can attribute them.
    pub install_id: Option<String>,
    pub key_id: Option<String>,
}

impl AuthFailure {
    pub fn new(status: u16, code: &'static str) -> Self {
        Self {
            status,
            code,
            install_id: None,
            key_id: None,
        }
    }

    pub fn with_ids(
        status: u16,
        code: &'static str,
        install_id: impl Into<String>,
        key_id: impl Into<String>,
    ) -> Self {
        Self {
            status,
            code,
            install_id: Some(install_id.into()),
            key_id: Some(key_id.into()),
        }
    }
}

#[allow(clippy::too_many_arguments)]
pub async fn authenticate_envelope(
    req: &mut Request,
    db: &D1Database,
    app_id: &str,
    app_attest_environment: &str,
    now: i64,
    method: &str,
    path: &str,
    max_body_bytes: usize,
    max_payload_bytes: usize,
) -> Result<std::result::Result<AuthenticatedPayload, AuthFailure>> {
    slice_c::authenticate_envelope_with_storage(
        req,
        &slice_c::D1AttestStorage(db),
        app_id,
        app_attest_environment,
        now,
        method,
        path,
        max_body_bytes,
        max_payload_bytes,
    )
    .await
}

async fn read_limited_envelope(
    req: &mut Request,
    max_bytes: usize,
) -> Result<std::result::Result<AuthenticatedEnvelope, AuthFailure>> {
    if content_length_exceeds(req.headers().get("content-length")?.as_deref(), max_bytes) {
        return Ok(Err(AuthFailure::new(413, "payload_too_large")));
    }

    let mut stream = req.stream()?;
    let mut bytes = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        if bytes.len().saturating_add(chunk.len()) > max_bytes {
            return Ok(Err(AuthFailure::new(413, "payload_too_large")));
        }
        bytes.extend_from_slice(&chunk);
    }

    match serde_json::from_slice(&bytes) {
        Ok(body) => Ok(Ok(body)),
        Err(_) => Ok(Err(AuthFailure::new(400, "invalid_json"))),
    }
}

fn content_length_exceeds(content_length: Option<&str>, max_bytes: usize) -> bool {
    content_length
        .and_then(|value| value.trim().parse::<usize>().ok())
        .map(|length| length > max_bytes)
        .unwrap_or(false)
}
