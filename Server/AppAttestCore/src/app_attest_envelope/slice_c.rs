//! Backend-neutral App Attest key lookup and exact-one replay protection.
use super::*;
use std::future::Future;

/// Futures intentionally need not be Send: they belong to one Worker invocation.
pub trait AttestStorage {
    fn read_key<'a>(
        &'a self,
        install: &'a str,
        key: &'a str,
    ) -> impl Future<Output = Result<Option<storage::AppAttestKeyRow>>> + 'a;
    fn compare_and_advance_counter<'a>(
        &'a self,
        install: &'a str,
        key: &'a str,
        previous: i64,
        next: i64,
        now: i64,
    ) -> impl Future<Output = Result<bool>> + 'a;
}

/// Existing shared consumers keep their native D1 operations and errors.
pub struct D1AttestStorage<'a>(pub &'a D1Database);
impl AttestStorage for D1AttestStorage<'_> {
    fn read_key<'a>(
        &'a self,
        install: &'a str,
        key: &'a str,
    ) -> impl Future<Output = Result<Option<storage::AppAttestKeyRow>>> + 'a {
        storage::key(self.0, install, key)
    }
    fn compare_and_advance_counter<'a>(
        &'a self,
        install: &'a str,
        key: &'a str,
        previous: i64,
        next: i64,
        now: i64,
    ) -> impl Future<Output = Result<bool>> + 'a {
        storage::update_key_counter(self.0, install, key, previous, next, now)
    }
}

#[allow(clippy::too_many_arguments)]
pub async fn authenticate_envelope_with_storage<S: AttestStorage>(
    req: &mut Request,
    storage: &S,
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

    let Some(key) = storage.read_key(install_id, &key_id).await? else {
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
    if !storage
        .compare_and_advance_counter(install_id, &key_id, key.sign_counter, next_counter, now)
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
