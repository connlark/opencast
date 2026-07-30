//! The shared post-crypto App Attest request tier: read the authenticated
//! envelope under a byte cap, look up the registered key, verify the
//! assertion against the exact method/path/payload binding, and advance the
//! sign counter. One copy for every worker; each projects what it needs from
//! `AuthenticatedPayload`.

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
    let body = match read_limited_envelope(req, max_body_bytes).await? {
        Ok(body) => body,
        Err(failure) => return Ok(Err(failure)),
    };
    let payload = body.payload.unwrap_or_default();
    if payload.len() > max_payload_bytes {
        return Ok(Err(AuthFailure::new(413, "payload_too_large")));
    }
    let Some(assertion) = body.assertion.as_deref() else {
        return Ok(Err(AuthFailure::new(401, "missing_assertion")));
    };
    let (Some(install_id), Some(raw_key_id)) = (body.install_id.as_deref(), body.key_id.as_deref())
    else {
        return Ok(Err(AuthFailure::new(401, "unknown_key")));
    };
    let key_id = match canonical_key_id(raw_key_id) {
        Ok(key_id) => key_id,
        Err(error) => return Ok(Err(AuthFailure::new(401, error.code()))),
    };

    let Some(key) = storage::key(db, install_id, &key_id).await? else {
        return Ok(Err(AuthFailure::new(401, "unknown_key")));
    };

    if key.app_id != app_id {
        return Ok(Err(AuthFailure::with_ids(
            401,
            "invalid_app_id",
            install_id,
            key_id.as_str(),
        )));
    }

    if key.environment != app_attest_environment {
        return Ok(Err(AuthFailure::with_ids(
            401,
            "invalid_environment",
            install_id,
            key_id.as_str(),
        )));
    }

    let previous_counter = match u32::try_from(key.sign_counter) {
        Ok(counter) => counter,
        Err(_) => {
            return Ok(Err(AuthFailure::with_ids(
                401,
                "invalid_counter",
                install_id,
                key_id.as_str(),
            )))
        }
    };
    let client_data_hash = request_client_data_hash(method, path, &payload);

    let verified = match verify_assertion(
        assertion,
        &client_data_hash,
        app_id,
        &key.public_key,
        previous_counter,
    ) {
        Ok(verified) => verified,
        Err(error) => {
            return Ok(Err(AuthFailure::with_ids(
                401,
                error.code(),
                install_id,
                key_id.as_str(),
            )))
        }
    };

    let next_counter = i64::from(verified.sign_counter);
    if !storage::update_key_counter(db, install_id, &key_id, key.sign_counter, next_counter, now)
        .await?
    {
        return Ok(Err(AuthFailure::with_ids(
            401,
            "invalid_counter",
            install_id,
            key_id.as_str(),
        )));
    }

    Ok(Ok(AuthenticatedPayload {
        install_id: install_id.to_string(),
        key_id,
        payload,
    }))
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
