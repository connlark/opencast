//! `TranscriptionJob` Durable Object: SQLite-backed, alarm-driven state
//! machine. Persist-before-advance, idempotent side effects, explicit
//! deletes at every stage, and no model call before a successful credit
//! reservation. The DO is the state authority; the D1 job index is a lookup
//! aid kept eventually consistent.

use std::rc::Rc;
use std::time::Duration;

use base64::Engine;
use futures_util::StreamExt;
use sha2::{Digest, Sha256};
use worker::{
    durable_object, wasm_bindgen, Date, DurableObject, Env, Fetch, Headers, Method, Request,
    RequestInit, RequestRedirect, Response, Result, State,
};

use crate::ad_analysis;
use crate::ai::{self, AiFailureClass};
use crate::config::AppConfig;
use crate::credit::{CreditAuthority, CreditError};
use crate::eta;
use crate::job::{self, JobRecord};
use crate::limiter::{
    LimiterAdmitRequest, LimiterBusyResponse, LimiterReleaseRequest, GLOBAL_LIMITER_OBJECT,
    LIMITER_ADMIT_PATH, LIMITER_INTERNAL_ORIGIN, LIMITER_RELEASE_PATH, USAGE_LIMITER_BINDING,
};
use crate::media::{
    self, MediaChunkRequest, MediaChunkResponse, MediaProbeRequest, MediaProbeResponse,
    MEDIA_BINDING, MEDIA_CHUNK_PATH, MEDIA_INTERNAL_ORIGIN, MEDIA_PROBE_PATH, MEDIA_WAKE_PATH,
};
use crate::route::JSON_CONTENT_TYPE;
use crate::stitch;
use crate::storage as d1;
use crate::types::{
    self, Balance, ErrorResponse, JobError, JobProgress, JobStatus, PollResponse, SourceIdentity,
    SCHEMA_VERSION,
};

const RECORD_KEY: &str = "job";
const RESULT_TTL_SECONDS: i64 = 7 * 24 * 60 * 60;
const BUSY_RETRY_SECONDS: u64 = 10;
const TRANSCRIPTION_BUCKET: &str = "TRANSCRIPTION_AUDIO";
const R2_PART_BYTES: usize = 8 * 1024 * 1024;

#[derive(serde::Serialize, serde::Deserialize)]
pub struct CreateMessage {
    pub job_id: String,
    pub account_id: String,
    pub episode_id: String,
    pub language_code: Option<String>,
    pub declared_duration_seconds: Option<f64>,
    pub enclosure_url: String,
    pub device_identity: Option<SourceIdentity>,
    /// Policy-unsafe enclosure URL (pass 2 decision 1): never fetched, never
    /// stored; the job goes straight to the exact-device upload path.
    #[serde(default)]
    pub origin_unsafe: bool,
    /// Chained cloud ad detection after stitching (validated by the gateway:
    /// the flag requires a non-empty `podcast_id`).
    #[serde(default)]
    pub ad_analysis_requested: bool,
    #[serde(default)]
    pub podcast_id: Option<String>,
    #[serde(default)]
    pub episode_title: Option<String>,
    #[serde(default)]
    pub podcast_title: Option<String>,
}

#[derive(serde::Deserialize)]
struct SourceMessage {
    source_identity: SourceIdentity,
}

#[derive(serde::Deserialize)]
struct UploadStartMessage {
    #[serde(default)]
    for_background: Option<bool>,
}

#[derive(serde::Deserialize)]
struct UploadPartsMessage {
    part_numbers: Vec<u16>,
    #[serde(default)]
    for_background: Option<bool>,
}

#[derive(serde::Deserialize)]
struct UploadCompleteMessage {
    parts: Vec<types::UploadCompletedPart>,
}

#[derive(serde::Deserialize)]
struct AckMessage {
    #[serde(default)]
    normalized_transcript_sha256: Option<String>,
}

#[durable_object(alarm)]
pub struct TranscriptionJob {
    state: Rc<State>,
    env: Env,
}

impl DurableObject for TranscriptionJob {
    fn new(state: State, env: Env) -> Self {
        Self {
            state: Rc::new(state),
            env,
        }
    }

    async fn fetch(&self, mut req: Request) -> Result<Response> {
        if req.method() != Method::Post {
            return json_error(405, "method_not_allowed");
        }
        match req.path().as_str() {
            "/create" => self.handle_create(&mut req).await,
            "/source" => self.handle_source(&mut req).await,
            "/poll" => self.handle_poll().await,
            "/result" => self.handle_result().await,
            "/ack" => self.handle_ack(&mut req).await,
            "/cancel" => self.handle_cancel().await,
            "/upload/start" => self.handle_upload_start(&mut req).await,
            "/upload/parts" => self.handle_upload_parts(&mut req).await,
            "/upload/complete" => self.handle_upload_complete(&mut req).await,
            _ => json_error(404, "not_found"),
        }
    }

    async fn alarm(&self) -> Result<Response> {
        if let Err(error) = self.advance().await {
            worker::console_error!("transcription job alarm error: {error:?}");
            // Try again later rather than wedging the job.
            self.schedule(Duration::from_secs(60)).await?;
        }
        Response::ok("")
    }
}

impl TranscriptionJob {
    fn config(&self) -> std::result::Result<AppConfig, ErrorResponse> {
        AppConfig::from_env(&self.env)
    }

    /// Credit seam: same call sites in every lane, backend selected by
    /// config (dev D1 fake vs the PurchaseWorker service binding).
    fn credit(&self, config: &AppConfig) -> Result<CreditAuthority> {
        CreditAuthority::from_env(&self.env, config)
    }

    async fn read_record(&self) -> Result<Option<JobRecord>> {
        let storage = self.state.storage();
        let Some(raw) = storage.get::<String>(RECORD_KEY).await? else {
            return Ok(None);
        };
        Ok(Some(serde_json::from_str(&raw).map_err(|error| {
            worker::Error::RustError(format!("job record decode: {error}"))
        })?))
    }

    async fn write_record(&self, record: &JobRecord) -> Result<()> {
        self.state
            .storage()
            .put(RECORD_KEY, serde_json::to_string(record)?)
            .await
    }

    /// Read-modify-write so long awaits elsewhere can't clobber concurrent
    /// route mutations. Returns the updated record. Every state transition
    /// stamps `phase_timestamps` here (first entry per state, epoch seconds)
    /// so no step can forget the telemetry.
    async fn update_record<F>(&self, mutate: F) -> Result<Option<JobRecord>>
    where
        F: FnOnce(&mut JobRecord),
    {
        let Some(mut record) = self.read_record().await? else {
            return Ok(None);
        };
        let previous_state = record.state.clone();
        mutate(&mut record);
        let now = now_seconds();
        if record.state != previous_state {
            record
                .phase_timestamps
                .entry(record.state.clone())
                .or_insert(now);
        }
        record.updated_at = now;
        self.write_record(&record).await?;
        Ok(Some(record))
    }

    async fn schedule(&self, delay: Duration) -> Result<()> {
        self.state.storage().set_alarm(delay).await
    }

    async fn schedule_at(&self, target_seconds: i64) -> Result<()> {
        let delay = target_seconds.saturating_sub(now_seconds()).max(0) as u64;
        self.schedule(Duration::from_secs(delay)).await
    }

    async fn sync_index(&self, record: &JobRecord) {
        if let Ok(db) = self.env.d1(crate::worker_app::TRANSCRIPTION_DB) {
            d1::update_job_state(&db, &record.job_id, &record.state, now_seconds())
                .await
                .ok();
        }
    }

    /// Best-effort content-free counter increment.
    async fn bump(&self, name: &str, delta: i64) {
        if let Ok(db) = self.env.d1(crate::worker_app::TRANSCRIPTION_DB) {
            d1::increment_counter(&db, name, delta, now_seconds())
                .await
                .ok();
        }
    }

    // --- Route handlers ---

    async fn handle_create(&self, req: &mut Request) -> Result<Response> {
        let message: CreateMessage = match req.json().await {
            Ok(message) => message,
            Err(_) => return json_error(400, types::ERROR_INVALID_REQUEST),
        };
        if let Some(record) = self.read_record().await? {
            // Duplicate (account, clientRequestID) attaches; never a second run.
            return self.status_response(&record, None);
        }

        let config = match self.config() {
            Ok(config) => config,
            Err(error) => return json_error_body(503, error),
        };
        let ciphertext = if message.origin_unsafe {
            None
        } else {
            let key = crate::crypto::resolve_key(
                self.env
                    .secret(crate::crypto::URL_ENCRYPTION_KEY_SECRET)
                    .ok()
                    .map(|secret| secret.to_string())
                    .as_deref(),
                config.is_development_lane(),
            )
            .map_err(|_| worker::Error::RustError("url encryption key unavailable".to_string()))?;
            let mut nonce = [0u8; 12];
            getrandom::getrandom(&mut nonce)
                .map_err(|error| worker::Error::RustError(error.to_string()))?;
            Some(
                crate::crypto::encrypt_string(&message.enclosure_url, &key, &nonce)
                    .map_err(|_| worker::Error::RustError("url encryption failed".to_string()))?,
            )
        };

        let now = now_seconds();
        let mut record = JobRecord::created(
            message.job_id,
            message.account_id,
            message.episode_id,
            message.language_code,
            message.declared_duration_seconds,
            ciphertext,
            message.device_identity,
            now,
        );
        record.origin_unsafe = message.origin_unsafe;
        record.ad_analysis_requested = message.ad_analysis_requested;
        record.podcast_id = message.podcast_id;
        record.episode_title = message.episode_title;
        record.podcast_title = message.podcast_title;
        record.state_deadline_at = Some(now + config.staging_origin_deadline_seconds);
        self.write_record(&record).await?;
        // Arm the alarm before the counter bump: a reset between write_record
        // and the alarm must not leave a durable job with no alarm, since
        // nothing re-arms a stranded job and it pins the account's active-job
        // slot (Phase 10 review RTW-4). The `jobs_created` D1 subrequest was
        // that gap; it now runs after the alarm exists. On the origin_unsafe
        // path enter_upload_path arms its own alarm at its tail.
        if message.origin_unsafe {
            // The server will never fetch this origin: skip staging entirely
            // and wait for the device's exact copy.
            let record = self.enter_upload_path(&config).await?;
            self.bump("jobs_created", 1).await;
            return self.status_response(&record, None);
        }
        self.schedule(Duration::from_secs(0)).await?;
        self.bump("jobs_created", 1).await;
        self.status_response(&record, None)
    }

    async fn handle_source(&self, req: &mut Request) -> Result<Response> {
        let message: SourceMessage = match req.json().await {
            Ok(message) => message,
            Err(_) => return json_error(400, types::ERROR_INVALID_REQUEST),
        };
        let Some(record) = self
            .update_record(|record| {
                if !job::is_terminal(&record.state) {
                    record.device_identity = Some(message.source_identity.clone());
                }
            })
            .await?
        else {
            return json_error(404, types::ERROR_JOB_NOT_FOUND);
        };

        if record.state == job::STATE_WAITING_FOR_DEVICE_SOURCE {
            self.schedule(Duration::from_secs(0)).await?;
        }
        self.status_response(&record, None)
    }

    async fn handle_poll(&self) -> Result<Response> {
        let Some(record) = self.read_record().await? else {
            return json_error(404, types::ERROR_JOB_NOT_FOUND);
        };
        let config = match self.config() {
            Ok(config) => config,
            Err(error) => return json_error_body(503, error),
        };
        let response = PollResponse {
            schema_version: SCHEMA_VERSION,
            job: job_status(
                &record,
                config.is_development_lane(),
                self.chunk_concurrency(&record, &config),
                now_seconds(),
            ),
            poll_after_seconds: config.poll_after_seconds,
        };
        json_success(200, &response)
    }

    async fn handle_result(&self) -> Result<Response> {
        let Some(record) = self.read_record().await? else {
            return json_error(404, types::ERROR_JOB_NOT_FOUND);
        };
        if record.state != job::STATE_RESULT_READY && record.state != job::STATE_DELIVERED {
            return json_error(409, types::ERROR_INVALID_REQUEST);
        }
        let bucket = self.env.bucket(TRANSCRIPTION_BUCKET)?;
        let key = job::r2_result_key(&record.job_id);
        let Some(object) = bucket.get(&key).execute().await? else {
            return json_error(410, types::ERROR_INTERNAL);
        };
        let Some(body) = object.body() else {
            return json_error(410, types::ERROR_INTERNAL);
        };
        let bytes = body.bytes().await?;
        if record.state == job::STATE_RESULT_READY {
            if let Some(updated) = self
                .update_record(|record| {
                    if record.state == job::STATE_RESULT_READY {
                        record.state = job::STATE_DELIVERED.to_string();
                    }
                })
                .await?
            {
                self.sync_index(&updated).await;
            }
        }
        let headers = Headers::new();
        headers.set("content-type", JSON_CONTENT_TYPE)?;
        headers.set("cache-control", "no-store")?;
        Ok(Response::builder()
            .with_status(200)
            .with_headers(headers)
            .fixed(bytes))
    }

    async fn handle_ack(&self, req: &mut Request) -> Result<Response> {
        let message: AckMessage = match req.json().await {
            Ok(message) => message,
            Err(_) => return json_error(400, types::ERROR_INVALID_REQUEST),
        };
        let Some(record) = self.read_record().await? else {
            return json_error(404, types::ERROR_JOB_NOT_FOUND);
        };
        match record.state.as_str() {
            job::STATE_RESULT_READY | job::STATE_DELIVERED => {}
            job::STATE_ACKNOWLEDGED => return self.status_response(&record, None),
            _ => return json_error(409, types::ERROR_INVALID_REQUEST),
        }

        // Cross-stack normalization tripwire: the client sends the hash of
        // the transcript it imported; compare against the stitched hash on
        // the record and count mismatches (content-free: job id + truncated
        // hashes only). The ack still proceeds either way — refusing would
        // hand a misbehaving client a lever to pin results/{job}/ for the
        // full result TTL.
        if let (Some(client_hash), Some(server_hash)) = (
            message.normalized_transcript_sha256.as_deref(),
            record.normalized_transcript_sha256.as_deref(),
        ) {
            if client_hash != server_hash {
                worker::console_warn!(
                    "job {} ack hash mismatch: client {}.. server {}..",
                    record.job_id,
                    client_hash.chars().take(8).collect::<String>(),
                    server_hash.chars().take(8).collect::<String>()
                );
                self.bump("ack_hash_mismatch", 1).await;
            }
        }

        // Ack deletes the result object immediately; the app only acks after
        // its durable local import.
        let bucket = self.env.bucket(TRANSCRIPTION_BUCKET)?;
        bucket.delete(&job::r2_result_key(&record.job_id)).await?;
        self.delete_job_prefixes(&record.job_id).await?;

        let updated = self
            .update_record(|record| {
                record.state = job::STATE_ACKNOWLEDGED.to_string();
                record.cleanup_complete = true;
                record.state_deadline_at = None;
            })
            .await?
            .expect("record existed above");
        self.sync_index(&updated).await;
        self.bump("jobs_acknowledged", 1).await;
        self.state.storage().delete_alarm().await?;
        self.status_response(&updated, None)
    }

    async fn handle_cancel(&self) -> Result<Response> {
        let Some(record) = self.read_record().await? else {
            return json_error(404, types::ERROR_JOB_NOT_FOUND);
        };
        if job::is_terminal(&record.state) {
            return self.status_response(&record, None);
        }
        let updated = self
            .update_record(|record| {
                if !job::is_terminal(&record.state) {
                    record.state = job::STATE_CANCELLING.to_string();
                }
            })
            .await?
            .expect("record existed above");
        // Run the cleanup inline so cancellation is prompt and idempotent;
        // alarms re-run it if we're evicted mid-way.
        let record = self
            .finish_terminal(updated, job::STATE_CANCELLED, types::ERROR_CANCELLED, None)
            .await?;
        self.status_response(&record, None)
    }

    // --- Exact-device upload routes (pass 2 decision 3) ---

    /// Mint presigned `UploadPart` URLs for the given part numbers. URLs are
    /// bearer credentials: bounded expiry, never logged.
    fn presign_parts(
        &self,
        record: &JobRecord,
        upload_id: &str,
        part_numbers: &[u16],
        expires_seconds: u32,
    ) -> std::result::Result<Vec<types::UploadPartGrant>, &'static str> {
        let settings = crate::config::UploadPresignSettings::from_env(&self.env)
            .ok_or(types::ERROR_UPLOAD_UNAVAILABLE)?;
        let now = now_seconds();
        let path = format!(
            "/{}/{}",
            settings.bucket,
            job::r2_upload_key(&record.job_id)
        );
        Ok(part_numbers
            .iter()
            .map(|&part_number| types::UploadPartGrant {
                part_number,
                url: crate::sigv4::presign_url(&crate::sigv4::PresignRequest {
                    method: "PUT",
                    host: &settings.host,
                    path: &path,
                    query: &[
                        ("partNumber", &part_number.to_string()),
                        ("uploadId", upload_id),
                    ],
                    access_key_id: &settings.access_key_id,
                    secret_access_key: &settings.secret_access_key,
                    region: "auto",
                    timestamp: now,
                    expires_seconds,
                }),
                expires_at: now + i64::from(expires_seconds),
            })
            .collect())
    }

    fn upload_url_expiry(&self, config: &AppConfig, for_background: Option<bool>) -> u32 {
        if for_background.unwrap_or(false) {
            config.upload_background_url_expires_seconds
        } else {
            config.upload_url_expires_seconds
        }
    }

    async fn handle_upload_start(&self, req: &mut Request) -> Result<Response> {
        let message: UploadStartMessage = match req.json().await {
            Ok(message) => message,
            Err(_) => return json_error(400, types::ERROR_INVALID_REQUEST),
        };
        let Some(record) = self.read_record().await? else {
            return json_error(404, types::ERROR_JOB_NOT_FOUND);
        };
        let config = match self.config() {
            Ok(config) => config,
            Err(error) => return json_error_body(503, error),
        };
        // Upload capability exists only for a job the server routed there.
        if record.state != job::STATE_EXACT_UPLOAD_REQUIRED
            && record.state != job::STATE_EXACT_UPLOADING
        {
            return json_error(409, types::ERROR_INVALID_REQUEST);
        }
        let Some(device) = record.device_identity.clone() else {
            // The device's exact identity gates the upload (parent abuse
            // rule); report /source first.
            return json_error(409, types::ERROR_INVALID_REQUEST);
        };
        if device.byte_count > config.max_source_bytes {
            // The device file itself violates the cap: upload can never
            // succeed, so this is the local-fallback failure card.
            self.finish_terminal(
                record,
                job::STATE_FAILED,
                types::ERROR_SOURCE_TOO_LARGE,
                None,
            )
            .await?;
            return json_error(400, types::ERROR_SOURCE_TOO_LARGE);
        }

        // Resume against the persisted geometry; a config change mid-job must
        // never change part boundaries (R2 requires byte-identical parts).
        let part_size = record
            .upload_part_size_bytes
            .unwrap_or(config.upload_part_bytes);
        let Some(part_count) = record
            .upload_part_count
            .or_else(|| job::upload_part_count(device.byte_count, part_size))
        else {
            return json_error(400, types::ERROR_INVALID_REQUEST);
        };

        let upload_id = match record.upload_id.clone() {
            Some(existing) => existing,
            None => {
                if crate::config::UploadPresignSettings::from_env(&self.env).is_none() {
                    // Fail closed BEFORE creating server state (decision 12).
                    return json_error(503, types::ERROR_UPLOAD_UNAVAILABLE);
                }
                let bucket = self.env.bucket(TRANSCRIPTION_BUCKET)?;
                let upload = bucket
                    .create_multipart_upload(&job::r2_upload_key(&record.job_id))
                    .execute()
                    .await?;
                let upload_id = upload.upload_id().await;
                let deadline = now_seconds() + config.exact_uploading_deadline_seconds;
                let updated = self
                    .update_record(|record| {
                        record.upload_id = Some(upload_id.clone());
                        record.upload_part_size_bytes = Some(part_size);
                        record.upload_part_count = Some(part_count);
                        record.state = job::STATE_EXACT_UPLOADING.to_string();
                        record.state_deadline_at = Some(deadline);
                    })
                    .await?
                    .expect("record existed above");
                self.sync_index(&updated).await;
                self.schedule_at(deadline).await?;
                upload_id
            }
        };

        let first_batch: Vec<u16> =
            (1..=part_count.min(job::UPLOAD_MAX_PARTS_PER_BATCH as u16)).collect();
        let expires = self.upload_url_expiry(&config, message.for_background);
        let parts = match self.presign_parts(&record, &upload_id, &first_batch, expires) {
            Ok(parts) => parts,
            Err(code) => return json_error(503, code),
        };
        json_success(
            200,
            &types::UploadGrantResponse {
                schema_version: SCHEMA_VERSION,
                upload_key_id: upload_id,
                part_size_bytes: part_size,
                part_count,
                parts,
            },
        )
    }

    async fn handle_upload_parts(&self, req: &mut Request) -> Result<Response> {
        let message: UploadPartsMessage = match req.json().await {
            Ok(message) => message,
            Err(_) => return json_error(400, types::ERROR_INVALID_REQUEST),
        };
        let Some(record) = self.read_record().await? else {
            return json_error(404, types::ERROR_JOB_NOT_FOUND);
        };
        let config = match self.config() {
            Ok(config) => config,
            Err(error) => return json_error_body(503, error),
        };
        if record.state != job::STATE_EXACT_UPLOADING {
            return json_error(409, types::ERROR_INVALID_REQUEST);
        }
        let (Some(upload_id), Some(part_count), Some(part_size)) = (
            record.upload_id.clone(),
            record.upload_part_count,
            record.upload_part_size_bytes,
        ) else {
            return json_error(409, types::ERROR_INVALID_REQUEST);
        };
        if message.part_numbers.is_empty()
            || message.part_numbers.len() > job::UPLOAD_MAX_PARTS_PER_BATCH
            || message
                .part_numbers
                .iter()
                .any(|&number| number == 0 || number > part_count)
        {
            return json_error(400, types::ERROR_INVALID_REQUEST);
        }
        let expires = self.upload_url_expiry(&config, message.for_background);
        let parts = match self.presign_parts(&record, &upload_id, &message.part_numbers, expires) {
            Ok(parts) => parts,
            Err(code) => return json_error(503, code),
        };
        json_success(
            200,
            &types::UploadGrantResponse {
                schema_version: SCHEMA_VERSION,
                upload_key_id: upload_id,
                part_size_bytes: part_size,
                part_count,
                parts,
            },
        )
    }

    async fn handle_upload_complete(&self, req: &mut Request) -> Result<Response> {
        let message: UploadCompleteMessage = match req.json().await {
            Ok(message) => message,
            Err(_) => return json_error(400, types::ERROR_INVALID_REQUEST),
        };
        let Some(record) = self.read_record().await? else {
            return json_error(404, types::ERROR_JOB_NOT_FOUND);
        };
        if record.state != job::STATE_EXACT_UPLOADING {
            // Idempotent repeat after the upload already advanced the job.
            if record.upload_completed {
                return self.status_response(&record, None);
            }
            return json_error(409, types::ERROR_INVALID_REQUEST);
        }
        let Some(upload_id) = record.upload_id.clone() else {
            return json_error(409, types::ERROR_INVALID_REQUEST);
        };
        let Some(device) = record.device_identity.clone() else {
            return json_error(409, types::ERROR_INVALID_REQUEST);
        };

        let bucket = self.env.bucket(TRANSCRIPTION_BUCKET)?;
        let key = job::r2_upload_key(&record.job_id);
        let parts: Vec<worker::UploadedPart> = message
            .parts
            .iter()
            .map(|part| worker::UploadedPart::new(part.part_number, part.etag.clone()))
            .collect();
        let upload = bucket.resume_multipart_upload(&key, &upload_id)?;
        let completed_size = match upload.complete(parts).await {
            Ok(object) => object.size() as i64,
            Err(_) => {
                // A crashed/duplicated complete may have consumed the
                // multipart upload after storing the object; accept only an
                // object that actually exists.
                match bucket.get(&key).execute().await? {
                    Some(object) => object.size() as i64,
                    None => return json_error(409, types::ERROR_INVALID_REQUEST),
                }
            }
        };
        if completed_size != device.byte_count {
            // Cheap early identity failure; the container hash check
            // (decision 5) is the authoritative gate for equal-size bytes.
            self.bump("upload_identity_mismatched", 1).await;
            self.finish_terminal(
                record,
                job::STATE_FAILED,
                types::ERROR_UPLOAD_IDENTITY_MISMATCH,
                None,
            )
            .await?;
            return json_error(400, types::ERROR_UPLOAD_IDENTITY_MISMATCH);
        }

        let updated = self
            .update_record(|record| {
                record.upload_completed = true;
                record.state = job::STATE_SOURCE_MATCHED.to_string();
                record.state_deadline_at = None;
            })
            .await?
            .expect("record existed above");
        self.sync_index(&updated).await;
        self.bump("exact_upload_completed", 1).await;
        self.schedule(Duration::from_secs(0)).await?;
        self.status_response(&updated, None)
    }

    // --- State machine driver ---

    async fn advance(&self) -> Result<()> {
        let Some(record) = self.read_record().await? else {
            return Ok(());
        };
        let config = self
            .config()
            .map_err(|error| worker::Error::RustError(error.error))?;

        // Deadlines drive the normal cancellation path — except the ad
        // phase, whose transcript is already stitched and settled: a missed
        // deadline there finalizes with the timeout marker instead.
        if let Some(deadline) = record.state_deadline_at {
            if !job::is_terminal(&record.state) && now_seconds() >= deadline {
                if record.state == job::STATE_DETECTING_ADS {
                    return self
                        .finalize_ad_phase(ad_analysis::failure_block(ad_analysis::MARKER_TIMEOUT))
                        .await;
                }
                self.finish_terminal(
                    record,
                    job::STATE_CANCELLED,
                    types::ERROR_DEADLINE_EXPIRED,
                    None,
                )
                .await?;
                return Ok(());
            }
        }

        match record.state.as_str() {
            job::STATE_CREATED => self.step_staging(record, &config).await,
            job::STATE_STAGING_ORIGIN => self.step_staging(record, &config).await,
            job::STATE_WAITING_FOR_DEVICE_SOURCE => {
                self.step_evaluate_identities(record, &config).await
            }
            job::STATE_EXACT_UPLOAD_REQUIRED | job::STATE_EXACT_UPLOADING => {
                // Nothing to drive server-side: the app owns the upload. The
                // alarm exists only so the state deadline fires.
                if let Some(deadline) = record.state_deadline_at {
                    self.schedule_at(deadline).await?;
                }
                Ok(())
            }
            job::STATE_SOURCE_MATCHED | job::STATE_PROBING => self.step_probe(&config).await,
            job::STATE_AWAITING_CREDITS => self.step_reserve(record, &config).await,
            job::STATE_RESERVED => self.step_chunk(&config).await,
            job::STATE_CHUNKING => self.step_chunk(&config).await,
            job::STATE_TRANSCRIBING => self.step_transcribe_wave(record, &config).await,
            job::STATE_STITCHING => self.step_stitch(record, &config).await,
            job::STATE_DETECTING_ADS => self.step_detect_ads(record, &config).await,
            job::STATE_RESULT_READY | job::STATE_DELIVERED => {
                // Result TTL backstop: settled either way; content is removed.
                // These states are non-terminal, so the top deadline gate only
                // fires at genuine expiry; an early alarm here (at-least-once
                // redelivery, or the alarm() catch's 60 s retry after a
                // post-write error) must NOT destroy an unexpired, already
                // settled+published result — re-arm at the deadline instead
                // (Phase 10 review RTW-2).
                match record.state_deadline_at {
                    Some(deadline) if now_seconds() < deadline => {
                        self.schedule_at(deadline).await?;
                        Ok(())
                    }
                    _ => {
                        self.finish_terminal(
                            record,
                            job::STATE_FAILED,
                            types::ERROR_DEADLINE_EXPIRED,
                            Some("result expired unacknowledged".to_string()),
                        )
                        .await?;
                        Ok(())
                    }
                }
            }
            job::STATE_CANCELLING => {
                self.finish_terminal(record, job::STATE_CANCELLED, types::ERROR_CANCELLED, None)
                    .await?;
                Ok(())
            }
            _ => Ok(()),
        }
    }

    async fn step_staging(&self, record: JobRecord, config: &AppConfig) -> Result<()> {
        // A3: wake the media container as the job starts so its cold start
        // overlaps staging and the device-hash wait instead of serializing
        // after them. /wake returns without waiting for readiness; any
        // failure changes nothing (probe/chunk already retry cold starts).
        if record.state == job::STATE_CREATED && !self.fake_media_enabled(config) {
            self.media_wake().await;
        }
        let record = self
            .update_record(|record| {
                record.state = job::STATE_STAGING_ORIGIN.to_string();
            })
            .await?
            .expect("record exists");
        self.sync_index(&record).await;

        let outcome = self.stage_origin(&record, config).await;
        match outcome {
            Ok((sha256, byte_count)) => {
                let updated = self
                    .update_record(|record| {
                        record.server_sha256 = Some(sha256);
                        record.server_byte_count = Some(byte_count);
                        record.enclosure_url_ciphertext = None;
                        record.state = job::STATE_WAITING_FOR_DEVICE_SOURCE.to_string();
                        record.state_deadline_at =
                            Some(now_seconds() + config.waiting_for_device_source_deadline_seconds);
                    })
                    .await?
                    .expect("record exists");
                self.sync_index(&updated).await;
                self.step_evaluate_identities(updated, config).await
            }
            Err(code) => {
                // Pass 2 decision 1: the server couldn't stage the origin
                // (podtrac/mgln class, over-cap mid-stream, transport). The
                // device's exact copy is the deterministic fallback — never
                // the failure card. `code` is deliberately dropped; the
                // failure class is content-free telemetry only.
                worker::console_log!(
                    "job {} origin staging failed ({code}); requesting exact upload",
                    record.job_id
                );
                self.enter_upload_path(config).await?;
                Ok(())
            }
        }
    }

    /// Route the job onto the exact-device upload path (pass 2 decision 1):
    /// any partial server copy is already gone (staging aborts its multipart;
    /// the mismatch path deletes the raw object before calling this), the
    /// encrypted URL is cleared, and the job waits for the device's bytes
    /// under its own 12 h deadline.
    async fn enter_upload_path(&self, config: &AppConfig) -> Result<JobRecord> {
        let bucket = self.env.bucket(TRANSCRIPTION_BUCKET)?;
        if let Some(record) = self.read_record().await? {
            bucket.delete(&job::r2_raw_key(&record.job_id)).await.ok();
        }
        let deadline = now_seconds() + config.exact_upload_required_deadline_seconds;
        let updated = self
            .update_record(|record| {
                record.enclosure_url_ciphertext = None;
                record.state = job::STATE_EXACT_UPLOAD_REQUIRED.to_string();
                record.state_deadline_at = Some(deadline);
            })
            .await?
            .expect("record exists");
        // Alarm first, telemetry second: sync_index and bump are D1
        // subrequests, and a reset while parked on them would otherwise leave
        // this durable record with no alarm — the exact stranding RTW-4
        // closed on the create paths (schedule_at is a storage op, so the
        // record write and the alarm arm commit as one gated stretch).
        // Phase 10 re-review: the original RTW-4 fix reordered handle_create
        // but left this interior gap.
        self.schedule_at(deadline).await?;
        self.sync_index(&updated).await;
        self.bump("exact_upload_required", 1).await;
        Ok(updated)
    }

    async fn step_evaluate_identities(&self, record: JobRecord, config: &AppConfig) -> Result<()> {
        match job::compare_identities(
            record.device_identity.as_ref(),
            record.server_sha256.as_deref(),
            record.server_byte_count,
        ) {
            job::IdentityComparison::Waiting => {
                if let Some(deadline) = record.state_deadline_at {
                    self.schedule_at(deadline).await?;
                }
                Ok(())
            }
            job::IdentityComparison::Matched => {
                let updated = self
                    .update_record(|record| {
                        record.state = job::STATE_SOURCE_MATCHED.to_string();
                        record.state_deadline_at = None;
                    })
                    .await?
                    .expect("record exists");
                self.sync_index(&updated).await;
                self.bump("source_matched", 1).await;
                self.schedule(Duration::from_secs(0)).await
            }
            job::IdentityComparison::Mismatched => {
                // DAI variant or stale device copy: delete the server copy
                // FIRST (parent rule), then request the device's exact bytes
                // instead of failing (pass 2 decision 1). Nothing is spent.
                let bucket = self.env.bucket(TRANSCRIPTION_BUCKET)?;
                bucket.delete(&job::r2_raw_key(&record.job_id)).await?;
                self.bump("source_mismatched", 1).await;
                self.enter_upload_path(config).await?;
                Ok(())
            }
        }
    }

    async fn step_probe(&self, config: &AppConfig) -> Result<()> {
        let updated = self
            .update_record(|record| {
                record.state = job::STATE_PROBING.to_string();
            })
            .await?
            .expect("record exists");
        self.sync_index(&updated).await;

        let probe = self.run_media_probe(&updated, config).await;
        let probe = match probe {
            Ok(probe) => probe,
            Err(failure) => return self.handle_media_failure(updated, config, failure).await,
        };
        let device = updated
            .device_identity
            .as_ref()
            .expect("matched implies device identity");
        if let Err(code) = media::validate_probe(
            &probe,
            &device.sha256,
            device.byte_count,
            config.max_canonical_duration_seconds,
            config.max_source_bytes,
        ) {
            // Decision 5: for an uploaded source, an identity mismatch means
            // the uploaded bytes are not the authenticated device report —
            // its own stable code, zero spend, prefix deleted.
            let code = if updated.upload_completed && code == types::ERROR_SOURCE_MISMATCH {
                self.bump("upload_identity_mismatched", 1).await;
                types::ERROR_UPLOAD_IDENTITY_MISMATCH
            } else {
                code
            };
            self.finish_terminal(updated, job::STATE_FAILED, code, None)
                .await?;
            return Ok(());
        }
        let Some(reserved_seconds) = job::reserved_seconds_for_duration(probe.duration_seconds)
        else {
            self.finish_terminal(
                updated,
                job::STATE_FAILED,
                types::ERROR_UNSUPPORTED_MEDIA_TYPE,
                None,
            )
            .await?;
            return Ok(());
        };

        let updated = self
            .update_record(|record| {
                // Pin the identity recomputed by the media worker from the
                // same exact R2 object whose duration becomes canonical.
                record.canonical_source_sha256 = Some(probe.sha256.clone());
                record.canonical_source_byte_count = Some(probe.byte_count);
                record.canonical_duration_seconds = Some(probe.duration_seconds);
                record.reserved_seconds = Some(reserved_seconds);
                record.media_attempts = 0;
            })
            .await?
            .expect("record exists");
        self.step_reserve(updated, config).await
    }

    async fn step_reserve(&self, record: JobRecord, config: &AppConfig) -> Result<()> {
        let Some(reserved_seconds) = record.reserved_seconds else {
            return Err(worker::Error::RustError(
                "reserve step without probe".to_string(),
            ));
        };
        let credit = self.credit(config)?;
        match credit
            .reserve(
                &record.account_id,
                &record.job_id,
                reserved_seconds,
                now_seconds(),
            )
            .await
        {
            Ok(_) => {
                let updated = self
                    .update_record(|record| {
                        record.state = job::STATE_RESERVED.to_string();
                        record.state_deadline_at = None;
                    })
                    .await?
                    .expect("record exists");
                self.sync_index(&updated).await;
                self.schedule(Duration::from_secs(0)).await
            }
            Err(CreditError::Insufficient) => {
                let updated = self
                    .update_record(|record| {
                        if record.state != job::STATE_AWAITING_CREDITS {
                            record.state = job::STATE_AWAITING_CREDITS.to_string();
                            record.state_deadline_at =
                                Some(now_seconds() + config.awaiting_credits_deadline_seconds);
                        }
                    })
                    .await?
                    .expect("record exists");
                self.sync_index(&updated).await;
                // Retry the reservation periodically, but never sleep past
                // the state deadline that ends the wait.
                let retry_at = now_seconds() + config.awaiting_credits_retry_seconds;
                let deadline = updated.state_deadline_at.unwrap_or(retry_at);
                self.schedule_at(retry_at.min(deadline)).await
            }
            Err(error) => Err(worker::Error::RustError(format!(
                "credit reserve failed: {error:?}"
            ))),
        }
    }

    async fn step_chunk(&self, config: &AppConfig) -> Result<()> {
        let record = self
            .update_record(|record| {
                record.state = job::STATE_CHUNKING.to_string();
                if record.chunk_work.is_empty() {
                    if let Some(total) = record
                        .canonical_duration_seconds
                        .and_then(eta::expected_chunk_count)
                    {
                        record.chunk_work = job::init_chunk_work(total, record.next_chunk_index);
                    }
                }
            })
            .await?
            .expect("record exists");
        self.sync_index(&record).await;

        // Lever 2 (pass 0.5): transcribe chunks while the container is still
        // writing the rest of them. Concurrency 1 keeps the strict pass-0
        // chunk-then-transcribe walk — the rollback story.
        let concurrency = self.chunk_concurrency(&record, config);
        let overlap = if concurrency > 1 {
            self.run_chunk_overlap(&record, config, concurrency).await?
        } else {
            OverlapReport {
                media: self.run_media_chunk(&record, config).await,
                fatal: None,
                defer_seconds: None,
            }
        };

        // A fatal chunk outcome ends the job regardless of how chunking
        // finished; the media call has already completed (the overlap driver
        // always awaits it), so cleanup cannot race container writes.
        if let Some(code) = overlap.fatal {
            self.release_and_fail(record, config, code).await?;
            return Ok(());
        }
        let chunk_response = match overlap.media {
            Ok(response) => response,
            Err(failure) => return self.handle_media_failure(record, config, failure).await,
        };
        let canonical = record.canonical_duration_seconds.unwrap_or_default();
        if let Err(code) = media::validate_chunks(
            &chunk_response.chunks,
            job::MAX_CHUNK_RAW_BYTES,
            canonical,
            job::CHUNK_SECONDS,
            job::STEP_SECONDS,
        ) {
            self.release_and_fail(record, config, code).await?;
            return Ok(());
        }
        let Some(validated_chunks) = chunk_response
            .chunks
            .iter()
            .map(|chunk| {
                media::valid_chunk_interval(chunk, canonical).map(
                    |(valid_start_seconds, valid_end_seconds)| job::ChunkRef {
                        index: chunk.index,
                        key: chunk.key.clone(),
                        requested_start_seconds: chunk.requested_start_seconds,
                        actual_duration_seconds: chunk.actual_duration_seconds,
                        valid_start_seconds,
                        valid_end_seconds,
                        byte_count: chunk.byte_count,
                        sha256: chunk.sha256.clone(),
                    },
                )
            })
            .collect::<Option<Vec<_>>>()
        else {
            worker::console_error!(
                "validated chunk interval reconstruction failed: job {}",
                record.job_id
            );
            self.release_and_fail(record, config, types::ERROR_INTERNAL)
                .await?;
            return Ok(());
        };

        // Merge the manifest without resurrecting a job a route handler
        // ended mid-chunking: cancel runs its cleanup inline, and blindly
        // setting TRANSCRIBING here would revive a cancelled job.
        let merged = self
            .update_record(|record| {
                if job::is_terminal(&record.state) || record.state == job::STATE_CANCELLING {
                    return;
                }
                record.chunks = validated_chunks;
                record.chunk_manifest_sha256 = Some(chunk_response.manifest_sha256.clone());
                record.chunk_audio_profile = chunk_response.chunk_audio_profile.clone();
                // Preserve overlap outcomes; entries the driver never
                // touched start fresh.
                let mut chunk_work = job::init_chunk_work(chunk_response.chunks.len() as u32, 0);
                for existing in &record.chunk_work {
                    if let Some(slot) = chunk_work.get_mut(existing.index as usize) {
                        *slot = existing.clone();
                    }
                }
                record.chunk_work = chunk_work;
                record.next_chunk_index = record
                    .chunk_work
                    .iter()
                    .filter(|work| work.completed)
                    .count() as u32;
                record.current_chunk_attempts = 0;
                record.media_attempts = 0;
                record.state = job::STATE_TRANSCRIBING.to_string();
            })
            .await?
            .expect("record exists");
        if job::is_terminal(&merged.state) {
            // Cancel finished the job mid-chunking; re-delete anything the
            // container wrote after that cleanup (idempotent).
            self.delete_job_prefixes(&merged.job_id).await.ok();
            return Ok(());
        }
        if merged.state == job::STATE_CANCELLING {
            return Ok(());
        }
        self.sync_index(&merged).await;
        self.schedule(Duration::from_secs(overlap.defer_seconds.unwrap_or(0)))
            .await
    }

    /// Lever 2 driver: discover chunks in R2 as the container writes them
    /// and give each at most ONE AI attempt while chunking runs; retries,
    /// busy pacing, and transport backoff all defer to the proven wave
    /// driver after the manifest merge. The media future is always awaited
    /// to completion so terminal cleanup never races container writes.
    async fn run_chunk_overlap(
        &self,
        record: &JobRecord,
        config: &AppConfig,
        concurrency: u32,
    ) -> Result<OverlapReport> {
        use std::cell::RefCell;
        use std::collections::{BTreeMap, BTreeSet};

        let canonical = record.canonical_duration_seconds.unwrap_or_default();
        let expected_chunks = ((canonical / job::STEP_SECONDS).ceil() as u32).max(1);
        let ceiling = job::retry_audio_ceiling_seconds(canonical, expected_chunks);
        let chunk_prefix = job::r2_chunk_prefix(&record.job_id);

        let media_slot: RefCell<
            Option<std::result::Result<MediaChunkResponse, media::MediaCallFailure>>,
        > = RefCell::new(None);
        let media_task = async {
            let result = self.run_media_chunk(record, config).await;
            *media_slot.borrow_mut() = Some(result);
        };

        let driver = async {
            // Seed from prior state so an alarm retry after an eviction
            // never re-spends a chunk that already has a durable response.
            let mut completed: BTreeSet<u32> = self
                .list_indices(&job::r2_response_prefix(&record.job_id), ".json")
                .await
                .unwrap_or_default();
            let mut prior_attempts: BTreeMap<u32, u32> = BTreeMap::new();
            let mut excluded: BTreeSet<u32> = completed.clone();
            for work in &record.chunk_work {
                if work.completed {
                    completed.insert(work.index);
                    excluded.insert(work.index);
                }
                if work.failed_attempts > 0 {
                    prior_attempts.insert(work.index, work.failed_attempts);
                    excluded.insert(work.index);
                }
            }
            let mut discovered: BTreeSet<u32> = completed.clone();
            let mut budgeted = record.requested_audio_seconds;
            let mut in_flight_count: u32 = 0;
            let mut in_flight = futures_util::stream::FuturesUnordered::new();
            let mut fatal: Option<&'static str> = None;
            let mut defer_seconds: Option<u64> = None;
            let mut halted = false;

            loop {
                let media_done = media_slot.borrow().is_some();
                if !halted {
                    // A route handler may have ended the job mid-overlap.
                    if let Ok(Some(current)) = self.read_record().await {
                        if job::is_terminal(&current.state)
                            || current.state == job::STATE_CANCELLING
                        {
                            halted = true;
                        }
                    }
                }
                if !halted && fatal.is_none() {
                    if media_done {
                        if let Some(Ok(response)) = media_slot.borrow().as_ref() {
                            discovered.extend(response.chunks.iter().map(|chunk| chunk.index));
                        }
                    } else if let Ok(listed) = self.list_indices(&chunk_prefix, ".mp3").await {
                        discovered.extend(listed);
                    }
                    // A wave is admitted once, before any of its AI calls.
                    // Wait for all siblings before filling the next wave so
                    // one limiter decision corresponds to one durable wave.
                    if in_flight_count == 0 {
                        let indexes = job::select_overlap(
                            &discovered,
                            &excluded,
                            concurrency,
                            budgeted,
                            ceiling,
                        );
                        if !indexes.is_empty() {
                            let current =
                                self.read_record().await?.unwrap_or_else(|| record.clone());
                            let wave_seconds = job::CHUNK_SECONDS * f64::from(indexes.len() as u32);
                            match self.limiter_admit(&current, wave_seconds, config).await {
                                Ok(LimiterOutcome::Admitted) => {
                                    self.clear_queue_state(&current).await?;
                                    for index in indexes {
                                        excluded.insert(index);
                                        budgeted += job::CHUNK_SECONDS;
                                        in_flight_count += 1;
                                        // Actual duration and hashes arrive
                                        // with the manifest; requested
                                        // duration is conservative here.
                                        let chunk = job::ChunkRef {
                                            index,
                                            key: format!("{chunk_prefix}{index}.mp3"),
                                            requested_start_seconds: index as f64
                                                * job::STEP_SECONDS,
                                            actual_duration_seconds: job::CHUNK_SECONDS,
                                            valid_start_seconds: index as f64 * job::STEP_SECONDS,
                                            valid_end_seconds: ((index as f64 * job::STEP_SECONDS)
                                                + job::CHUNK_SECONDS)
                                                .min(
                                                    record
                                                        .canonical_duration_seconds
                                                        .unwrap_or_default(),
                                                ),
                                            byte_count: 0,
                                            sha256: String::new(),
                                        };
                                        let attempts =
                                            prior_attempts.get(&index).copied().unwrap_or(0);
                                        in_flight
                                            .push(self.run_chunk(record, config, chunk, attempts));
                                    }
                                }
                                Ok(LimiterOutcome::Busy {
                                    queue_position,
                                    wait_seconds,
                                }) => {
                                    self.record_queue_denial(queue_position, wait_seconds)
                                        .await?;
                                    defer_seconds = Some(BUSY_RETRY_SECONDS);
                                    halted = true;
                                }
                                Ok(LimiterOutcome::SpendCapped) => {
                                    fatal = Some(types::ERROR_RATE_LIMITED);
                                    halted = true;
                                }
                                Err(error) => {
                                    worker::console_error!(
                                        "limiter admit transport error: {error:?}"
                                    );
                                    defer_seconds = Some(60);
                                    halted = true;
                                }
                            }
                        }
                    }
                }

                if in_flight_count == 0 && media_done {
                    break;
                }
                if in_flight_count > 0 {
                    // Progress the AI calls, but wake at least every 750 ms
                    // so freshly written chunks are discovered promptly.
                    let outcome = {
                        let completion = in_flight.select_next_some();
                        let tick = worker::Delay::from(Duration::from_millis(750));
                        futures_util::pin_mut!(completion, tick);
                        match futures_util::future::select(completion, tick).await {
                            futures_util::future::Either::Left((outcome, _)) => Some(outcome),
                            futures_util::future::Either::Right(_) => None,
                        }
                    };
                    if let Some(outcome) = outcome {
                        in_flight_count -= 1;
                        self.apply_overlap_outcome(
                            outcome,
                            config,
                            &mut completed,
                            &mut prior_attempts,
                            &mut fatal,
                        )
                        .await?;
                    }
                } else {
                    worker::Delay::from(Duration::from_millis(750)).await;
                }
            }
            worker::console_log!(
                "overlap driver done: job {} completed {} discovered {} halted {}",
                record.job_id,
                completed.len(),
                discovered.len(),
                halted
            );
            Ok::<(Option<&'static str>, Option<u64>), worker::Error>((fatal, defer_seconds))
        };

        let ((), driver_result) = futures_util::join!(media_task, driver);
        let (fatal, defer_seconds) = driver_result?;
        let media = media_slot
            .into_inner()
            .expect("media task stores its result before completing");
        Ok(OverlapReport {
            media,
            fatal,
            defer_seconds,
        })
    }

    /// Per-completion bookkeeping for the overlap driver: successes and AI
    /// failures persist immediately (spend counted on every attempt, at the
    /// requested-duration estimate); busy/transport/missing outcomes leave
    /// the chunk pending for the wave driver.
    async fn apply_overlap_outcome(
        &self,
        outcome: ChunkOutcome,
        config: &AppConfig,
        completed: &mut std::collections::BTreeSet<u32>,
        prior_attempts: &mut std::collections::BTreeMap<u32, u32>,
        fatal: &mut Option<&'static str>,
    ) -> Result<()> {
        match outcome.result {
            ChunkCallResult::Success | ChunkCallResult::AlreadyTranscribed => {
                let ran_ai = matches!(outcome.result, ChunkCallResult::Success);
                completed.insert(outcome.index);
                self.update_record(|record| {
                    if ran_ai {
                        record.requested_audio_seconds += outcome.attempt_seconds;
                    }
                    upsert_chunk_work(record, outcome.index, |work| {
                        work.completed = true;
                        work.retry_not_before = None;
                        if ran_ai {
                            work.ai_started_at.get_or_insert(outcome.ai_started_at);
                            work.ai_ended_at = Some(outcome.ai_ended_at);
                        }
                    });
                    record.next_chunk_index = record
                        .chunk_work
                        .iter()
                        .filter(|work| work.completed)
                        .count() as u32;
                })
                .await?;
            }
            ChunkCallResult::AiError { sanitized, class } => {
                let backoff = 5 + (Date::now().as_millis() % 3_000) / 1_000;
                let retry_at = now_seconds() + backoff as i64;
                let attempts = prior_attempts
                    .entry(outcome.index)
                    .and_modify(|count| *count += 1)
                    .or_insert(1);
                let attempts = *attempts;
                self.update_record(|record| {
                    record.requested_audio_seconds += outcome.attempt_seconds;
                    record.error_message = Some(sanitized);
                    upsert_chunk_work(record, outcome.index, |work| {
                        work.failed_attempts = attempts;
                        work.ai_started_at.get_or_insert(outcome.ai_started_at);
                        work.retry_not_before = Some(retry_at);
                    });
                })
                .await?;
                if class == AiFailureClass::Fatal || attempts >= config.max_chunk_attempts {
                    *fatal = Some(types::ERROR_TRANSCRIPTION_FAILED);
                }
            }
            // Transport hiccups and read races stay pending; the wave driver
            // applies its usual pacing after the manifest merge.
            ChunkCallResult::TransportError | ChunkCallResult::MissingChunkObject => {}
        }
        Ok(())
    }

    async fn list_indices(
        &self,
        prefix: &str,
        suffix: &str,
    ) -> Result<std::collections::BTreeSet<u32>> {
        let bucket = self.env.bucket(TRANSCRIPTION_BUCKET)?;
        let listing = bucket.list().prefix(prefix.to_string()).execute().await?;
        Ok(listing
            .objects()
            .iter()
            .filter_map(|object| {
                object
                    .key()
                    .strip_prefix(prefix)?
                    .strip_suffix(suffix)?
                    .parse()
                    .ok()
            })
            .collect())
    }

    /// Bounded chunk fan-out (pass 0.5 A1): one alarm turn runs one wave of
    /// up to `CHUNK_AI_CONCURRENCY` chunk futures joined together, persisting
    /// each completion as it lands. `CHUNK_AI_CONCURRENCY=1` reproduces the
    /// pass-0 sequential walk. All record writes happen in this driver loop
    /// (one completion at a time), so they never interleave; concurrent route
    /// mutations stay safe through the same read-modify-write pattern.
    async fn step_transcribe_wave(&self, record: JobRecord, config: &AppConfig) -> Result<()> {
        if record.state == job::STATE_CANCELLING || job::is_terminal(&record.state) {
            return Ok(());
        }
        // Initialize per-chunk work state; an in-flight pass-0 record (only
        // next_chunk_index) migrates to the same walk position.
        let record = if record.chunk_work.len() != record.chunks.len() {
            self.update_record(|record| {
                record.chunk_work =
                    job::init_chunk_work(record.chunks.len() as u32, record.next_chunk_index);
            })
            .await?
            .expect("record exists")
        } else {
            record
        };

        let canonical = record.canonical_duration_seconds.unwrap_or_default();
        let ceiling = job::retry_audio_ceiling_seconds(canonical, record.chunks.len() as u32);
        let durations: Vec<f64> = record
            .chunks
            .iter()
            .map(|chunk| chunk.actual_duration_seconds)
            .collect();
        let concurrency = self.chunk_concurrency(&record, config);

        let indexes = match job::select_wave(
            &record.chunk_work,
            &durations,
            concurrency,
            record.requested_audio_seconds,
            ceiling,
            now_seconds(),
        ) {
            job::WaveSelection::Complete => {
                return self.transition_to_stitching().await;
            }
            job::WaveSelection::WaitUntil(at) => return self.schedule_at(at).await,
            job::WaveSelection::ExceedsRetryCeiling => {
                // Retry-audio ceiling: service spend cap, never a customer
                // charge (same rule and error as the pass-0 walk).
                self.release_and_fail(record, config, types::ERROR_TRANSCRIPTION_FAILED)
                    .await?;
                return Ok(());
            }
            job::WaveSelection::Issue(indexes) => indexes,
        };

        let wave_seconds = indexes
            .iter()
            .filter_map(|&index| record.chunks.get(index as usize))
            .map(|chunk| chunk.actual_duration_seconds)
            .sum();
        match self.limiter_admit(&record, wave_seconds, config).await {
            Ok(LimiterOutcome::Admitted) => self.clear_queue_state(&record).await?,
            Ok(LimiterOutcome::Busy {
                queue_position,
                wait_seconds,
            }) => {
                self.record_queue_denial(queue_position, wait_seconds)
                    .await?;
                return self.schedule(Duration::from_secs(BUSY_RETRY_SECONDS)).await;
            }
            Ok(LimiterOutcome::SpendCapped) => {
                self.release_and_fail(record, config, types::ERROR_RATE_LIMITED)
                    .await?;
                return Ok(());
            }
            Err(error) => {
                worker::console_error!("limiter admit transport error: {error:?}");
                return self.schedule(Duration::from_secs(60)).await;
            }
        }

        let mut in_flight: futures_util::stream::FuturesUnordered<_> = indexes
            .iter()
            .map(|&index| {
                let chunk = record.chunks[index as usize].clone();
                let prior_failed_attempts = record.chunk_work[index as usize].failed_attempts;
                self.run_chunk(&record, config, chunk, prior_failed_attempts)
            })
            .collect();

        // Decision 3: a fatal outcome stops new waves, but in-flight siblings
        // are always awaited — their spend is counted, then discarded.
        let mut fatal: Option<&'static str> = None;
        let mut saw_transport_error = false;
        while let Some(outcome) = in_flight.next().await {
            match outcome.result {
                ChunkCallResult::Success | ChunkCallResult::AlreadyTranscribed => {
                    let ran_ai = matches!(outcome.result, ChunkCallResult::Success);
                    self.update_record(|record| {
                        if ran_ai {
                            record.requested_audio_seconds += outcome.attempt_seconds;
                        }
                        if let Some(work) = record
                            .chunk_work
                            .iter_mut()
                            .find(|work| work.index == outcome.index)
                        {
                            work.completed = true;
                            work.retry_not_before = None;
                            if ran_ai {
                                work.ai_started_at.get_or_insert(outcome.ai_started_at);
                                work.ai_ended_at = Some(outcome.ai_ended_at);
                            }
                        }
                        // Legacy mirror: chunks_completed stays monotonic and
                        // order-independent as a pure count.
                        record.next_chunk_index = record
                            .chunk_work
                            .iter()
                            .filter(|work| work.completed)
                            .count() as u32;
                    })
                    .await?;
                }
                ChunkCallResult::MissingChunkObject => fatal = Some(types::ERROR_INTERNAL),
                ChunkCallResult::TransportError => saw_transport_error = true,
                ChunkCallResult::AiError { sanitized, class } => {
                    // Jittered per-chunk retry backoff, same shape as pass 0.
                    let backoff = 5 + (Date::now().as_millis() % 3_000) / 1_000;
                    let retry_at = now_seconds() + backoff as i64;
                    let mut failed_attempts = 0;
                    self.update_record(|record| {
                        record.requested_audio_seconds += outcome.attempt_seconds;
                        record.error_message = Some(sanitized);
                        if let Some(work) = record
                            .chunk_work
                            .iter_mut()
                            .find(|work| work.index == outcome.index)
                        {
                            work.failed_attempts += 1;
                            work.ai_started_at.get_or_insert(outcome.ai_started_at);
                            work.retry_not_before = Some(retry_at);
                            failed_attempts = work.failed_attempts;
                        }
                    })
                    .await?;
                    if class == AiFailureClass::Fatal
                        || failed_attempts >= config.max_chunk_attempts
                    {
                        fatal = Some(types::ERROR_TRANSCRIPTION_FAILED);
                    }
                }
            }
        }

        // A route handler may have ended the job mid-wave (cancel runs its
        // cleanup inline); re-read before deciding what happens next.
        let Some(current) = self.read_record().await? else {
            return Ok(());
        };
        if job::is_terminal(&current.state) {
            // Terminal cleanup already ran; delete anything the in-flight
            // completions re-created after it (idempotent).
            self.delete_job_prefixes(&current.job_id).await.ok();
            return Ok(());
        }
        if current.state == job::STATE_CANCELLING {
            return Ok(());
        }
        if let Some(code) = fatal {
            self.release_and_fail(current, config, code).await?;
            return Ok(());
        }
        if current.chunk_work.iter().all(|work| work.completed) {
            return self.transition_to_stitching().await;
        }
        if saw_transport_error {
            // Infrastructure hiccup (limiter/R2 transport): pass-0 alarms
            // retried these at 60 s; keep that pacing.
            return self.schedule(Duration::from_secs(60)).await;
        }
        // Remaining chunks are backing off or awaiting the next wave; the
        // next turn's select_wave computes the exact delay.
        self.schedule(Duration::from_secs(0)).await
    }

    async fn transition_to_stitching(&self) -> Result<()> {
        let updated = self
            .update_record(|record| {
                record.state = job::STATE_STITCHING.to_string();
            })
            .await?
            .expect("record exists");
        self.sync_index(&updated).await;
        self.schedule(Duration::from_secs(0)).await
    }

    /// FAKE_AI test hooks may pin a per-job concurrency (workerd A/B proof);
    /// deploys tune the real knob via `CHUNK_AI_CONCURRENCY`.
    fn chunk_concurrency(&self, record: &JobRecord, config: &AppConfig) -> u32 {
        if self.fake_ai_enabled(config) {
            if let Some(concurrency) =
                ai::parse_fake_hooks(record.language_code.as_deref()).concurrency_override
            {
                return concurrency.clamp(1, 8);
            }
        }
        config.chunk_ai_concurrency
    }

    /// One chunk's admission → read → AI → persist sequence. Never touches
    /// the job record: the wave driver owns every record write. Internal
    /// transport errors map to `TransportError` so sibling chunks survive.
    async fn run_chunk(
        &self,
        record: &JobRecord,
        config: &AppConfig,
        chunk: job::ChunkRef,
        prior_failed_attempts: u32,
    ) -> ChunkOutcome {
        let mut outcome = ChunkOutcome {
            index: chunk.index,
            attempt_seconds: chunk.actual_duration_seconds,
            ai_started_at: 0,
            ai_ended_at: 0,
            result: ChunkCallResult::TransportError,
        };

        let audio = match self.read_chunk_audio(&chunk.key).await {
            Ok(Some(audio)) => audio,
            Ok(None) => {
                // A missing chunk with a durable response means a previous
                // turn already transcribed it (and deleted the audio) but
                // its record write was lost — e.g. a DO reset mid-turn with
                // side effects still landing. The AI output is what stitch
                // needs; self-heal instead of failing the job.
                let response_key = job::r2_response_key(&record.job_id, chunk.index);
                match self.read_chunk_audio(&response_key).await {
                    Ok(Some(_)) => {
                        worker::console_log!(
                            "chunk audio gone but response durable; self-healing: job {} index {}",
                            record.job_id,
                            chunk.index
                        );
                        outcome.result = ChunkCallResult::AlreadyTranscribed;
                    }
                    Ok(None) => {
                        worker::console_error!(
                            "chunk object missing at read: job {} index {}",
                            record.job_id,
                            chunk.index
                        );
                        outcome.result = ChunkCallResult::MissingChunkObject;
                    }
                    Err(error) => {
                        worker::console_error!("response probe transport error: {error:?}");
                    }
                }
                return outcome;
            }
            Err(error) => {
                worker::console_error!("chunk read transport error: {error:?}");
                return outcome;
            }
        };

        self.bump("ai_attempts", 1).await;
        outcome.ai_started_at = now_seconds();
        let ai_result = self
            .run_ai(record, config, &audio, chunk.index, prior_failed_attempts)
            .await;
        outcome.ai_ended_at = now_seconds();

        match ai_result {
            Ok(response_json) => {
                let persisted: Result<()> = async {
                    let bucket = self.env.bucket(TRANSCRIPTION_BUCKET)?;
                    bucket
                        .put(
                            &job::r2_response_key(&record.job_id, chunk.index),
                            response_json,
                        )
                        .execute()
                        .await?;
                    // Chunk audio is deleted only after its response is durable.
                    bucket.delete(&chunk.key).await?;
                    Ok(())
                }
                .await;
                match persisted {
                    Ok(()) => outcome.result = ChunkCallResult::Success,
                    Err(error) => {
                        worker::console_error!("chunk response persist error: {error:?}");
                    }
                }
            }
            Err(sanitized) => {
                let class = ai::classify_ai_error(&sanitized);
                outcome.result = ChunkCallResult::AiError { sanitized, class };
            }
        }
        outcome
    }

    async fn read_chunk_audio(&self, key: &str) -> Result<Option<Vec<u8>>> {
        let bucket = self.env.bucket(TRANSCRIPTION_BUCKET)?;
        let Some(object) = bucket.get(key).execute().await? else {
            return Ok(None);
        };
        let Some(body) = object.body() else {
            return Ok(None);
        };
        Ok(Some(body.bytes().await?))
    }

    async fn step_stitch(&self, record: JobRecord, config: &AppConfig) -> Result<()> {
        let bucket = self.env.bucket(TRANSCRIPTION_BUCKET)?;
        let canonical = record.canonical_duration_seconds.unwrap_or_default();
        let mut chunk_transcriptions = Vec::with_capacity(record.chunks.len());
        for chunk in &record.chunks {
            let key = job::r2_response_key(&record.job_id, chunk.index);
            let Some(object) = bucket.get(&key).execute().await? else {
                worker::console_error!("stitch input missing: job {} key {key}", record.job_id);
                self.release_and_fail(record, config, types::ERROR_INTERNAL)
                    .await?;
                return Ok(());
            };
            let Some(body) = object.body() else {
                worker::console_error!("stitch input empty body: job {} key {key}", record.job_id);
                self.release_and_fail(record, config, types::ERROR_INTERNAL)
                    .await?;
                return Ok(());
            };
            let bytes = body.bytes().await?;
            let response: ai::WhisperResponse = serde_json::from_slice(&bytes)
                .map_err(|error| worker::Error::RustError(format!("response decode: {error}")))?;
            chunk_transcriptions.push(
                response.to_chunk_transcription(chunk.valid_start_seconds, chunk.valid_end_seconds),
            );
        }

        let stitched = match stitch::stitch(&chunk_transcriptions, job::OVERLAP_SECONDS, canonical)
        {
            Ok(stitched) => stitched,
            Err(error) => {
                worker::console_error!(
                    "stitch rejected transcript: job {} error {error:?}",
                    record.job_id
                );
                self.preserve_stitch_debug_responses(&record, config).await;
                self.release_and_fail(record, config, types::ERROR_TRANSCRIPTION_FAILED)
                    .await?;
                return Ok(());
            }
        };
        if stitched.interval_trimmed_word_count > 0 {
            worker::console_log!(
                "stitch bounded model padding: job {} interval_trimmed_words {}",
                record.job_id,
                stitched.interval_trimmed_word_count
            );
            self.bump(
                "stitch_interval_trimmed_words",
                i64::try_from(stitched.interval_trimmed_word_count).unwrap_or(i64::MAX),
            )
            .await;
        }
        if stitched.empty_model_word_count > 0 {
            worker::console_log!(
                "stitch dropped empty model words: job {} empty_model_words {}",
                record.job_id,
                stitched.empty_model_word_count
            );
            self.bump(
                "stitch_empty_model_words",
                i64::try_from(stitched.empty_model_word_count).unwrap_or(i64::MAX),
            )
            .await;
        }
        if stitched.reversed_timing_word_count > 0 {
            worker::console_log!(
                "stitch dropped reversed model word timings: job {} reversed_timing_words {}",
                record.job_id,
                stitched.reversed_timing_word_count
            );
            self.bump(
                "stitch_reversed_timing_words",
                i64::try_from(stitched.reversed_timing_word_count).unwrap_or(i64::MAX),
            )
            .await;
        }

        let device = record
            .device_identity
            .clone()
            .expect("matched implies device identity");
        let (Some(canonical_source_sha256), Some(canonical_source_byte_count)) = (
            record.canonical_source_sha256.clone(),
            record.canonical_source_byte_count,
        ) else {
            worker::console_error!(
                "result publication verification failed: job {} missing canonical source proof",
                record.job_id
            );
            self.preserve_stitch_debug_responses(&record, config).await;
            self.release_and_fail(record, config, types::ERROR_TRANSCRIPTION_FAILED)
                .await?;
            return Ok(());
        };
        let verification_context = crate::result_validation::ResultVerificationContext {
            schema_version: SCHEMA_VERSION,
            source_sha256: &canonical_source_sha256,
            source_byte_count: canonical_source_byte_count,
            expected_source_sha256: &device.sha256,
            expected_source_byte_count: device.byte_count,
            duration_seconds: canonical,
        };
        if let Err(error) = crate::result_validation::verify(&stitched, &verification_context) {
            worker::console_error!(
                "result publication verification failed: job {} error {error:?}",
                record.job_id
            );
            self.preserve_stitch_debug_responses(&record, config).await;
            self.release_and_fail(record, config, types::ERROR_TRANSCRIPTION_FAILED)
                .await?;
            return Ok(());
        }
        let language = record.language_code.clone().unwrap_or_else(|| "en".into());
        let result = serde_json::json!({
            "schema_version": SCHEMA_VERSION,
            "result": {
                "schema_version": SCHEMA_VERSION,
                "source_identity": {
                    "sha256": canonical_source_sha256,
                    "byte_count": canonical_source_byte_count,
                    "duration_seconds": canonical,
                },
                "language_code": language,
                "duration_seconds": canonical,
                "text": stitched.text,
                "segments": stitched.segments.iter().map(|segment| serde_json::json!({
                    "id": segment.id,
                    "start": segment.start,
                    "end": segment.end,
                    "text": segment.text,
                    "words": segment.words.iter().map(|word| serde_json::json!({
                        "start": word.start,
                        "end": word.end,
                        "text": word.text,
                    })).collect::<Vec<_>>(),
                })).collect::<Vec<_>>(),
                "provenance": {
                    "provider": "cloudflare-workers-ai",
                    "model_identifier": config.model,
                    "serving_contract_version": "1",
                    "request_settings_sha256": ai::request_settings_sha256(
                        &config.model,
                        record.language_code.as_deref(),
                    ),
                    "chunk_manifest_sha256": record.chunk_manifest_sha256.clone().unwrap_or_default(),
                    "chunk_audio_profile": record.chunk_audio_profile.as_deref().unwrap_or("mp3-stream-copy-v1"),
                    "normalized_transcript_sha256": stitched.normalized_transcript_sha256,
                    "pipeline_version": stitch::PIPELINE_VERSION,
                    // Additive (pass 2): how the source bytes were proven.
                    "source_match_mode": if record.upload_completed {
                        "exact_device_upload"
                    } else {
                        "server_device_hash_match"
                    },
                },
                "warnings": [],
            },
        });
        bucket
            .put(
                &job::r2_result_key(&record.job_id),
                serde_json::to_vec(&result)?,
            )
            .execute()
            .await?;

        // Result durable: delete responses and the source object (staged or
        // uploaded — both keys, idempotently), release the inference slot,
        // settle exactly the reservation.
        for chunk in &record.chunks {
            bucket
                .delete(&job::r2_response_key(&record.job_id, chunk.index))
                .await?;
        }
        bucket.delete(&job::r2_raw_key(&record.job_id)).await?;
        bucket.delete(&job::r2_upload_key(&record.job_id)).await?;
        self.limiter_release(&record.job_id).await.ok();

        let credit = self.credit(config)?;
        credit
            .settle(&record.job_id, now_seconds())
            .await
            .map_err(|error| worker::Error::RustError(format!("settle failed: {error:?}")))?;
        self.bump(
            "settled_seconds",
            record.reserved_seconds.unwrap_or_default(),
        )
        .await;
        self.bump("results_ready", 1).await;

        let normalized = stitch::normalized_transcript_sha256(
            &chunk_transcriptions
                .iter()
                .flat_map(|chunk| chunk.segments.iter())
                .flat_map(|segment| segment.words.iter())
                .map(|word| word.text.clone())
                .collect::<Vec<_>>()
                .join(" "),
        );
        let _ = normalized;
        // Flag on → the ad phase runs before result_ready under its own
        // deadline; flag off → today's result_ready transition unchanged.
        let ad_deadline = now_seconds() + config.ad_analysis_deadline_seconds;
        let updated = self
            .update_record(|record| {
                if record.ad_analysis_requested {
                    record.state = job::STATE_DETECTING_ADS.to_string();
                    record.state_deadline_at = Some(ad_deadline);
                } else {
                    record.state = job::STATE_RESULT_READY.to_string();
                    record.state_deadline_at = Some(now_seconds() + RESULT_TTL_SECONDS);
                }
                record.result_key = Some(job::r2_result_key(&record.job_id));
                record.normalized_transcript_sha256 =
                    Some(stitched.normalized_transcript_sha256.clone());
            })
            .await?
            .expect("record exists");
        self.sync_index(&updated).await;
        if updated.state == job::STATE_DETECTING_ADS {
            self.schedule(Duration::from_secs(0)).await
        } else {
            self.schedule_at(updated.state_deadline_at.expect("just set"))
                .await
        }
    }

    /// One ad-phase alarm turn: poll the fingerprint-keyed internal job when
    /// one is recorded, otherwise submit (bounded attempts; fingerprint
    /// keying makes retries attach instead of re-running Gemini). Every
    /// terminal outcome finalizes into `result_ready` — the phase can only
    /// delay the transcript, never lose it.
    async fn step_detect_ads(&self, record: JobRecord, config: &AppConfig) -> Result<()> {
        if !config.ad_analysis_enabled {
            return self
                .finalize_ad_phase(ad_analysis::failure_block(ad_analysis::MARKER_UNAVAILABLE))
                .await;
        }
        if let Some(ad_job_id) = record.ad_analysis_job_id.clone() {
            let body = serde_json::json!({ "job_id": ad_job_id }).to_string();
            let response = self
                .ad_analysis_post(&ad_analysis::ad_analysis_poll_path(&ad_job_id), body)
                .await;
            return self.apply_ad_outcome(record, config, response).await;
        }

        if record.ad_analysis_attempts >= config.ad_analysis_max_submit_attempts {
            return self
                .finalize_ad_phase(ad_analysis::failure_block(ad_analysis::MARKER_FAILED))
                .await;
        }
        let Some(envelope) = self.read_result_envelope(&record.job_id).await? else {
            // The result object is gone mid-phase (a raced cancel's cleanup);
            // the terminal path owns the record now.
            return Ok(());
        };
        let request =
            match ad_analysis::build_request(&record, &envelope, &config.model, now_seconds()) {
                Ok(request) => request,
                Err(reason) => {
                    worker::console_log!(
                        "job {} ad analysis request build failed ({reason})",
                        record.job_id
                    );
                    return self
                        .finalize_ad_phase(ad_analysis::failure_block(ad_analysis::MARKER_FAILED))
                        .await;
                }
            };
        // Count the attempt before the call so a crash mid-submit stays
        // bounded; a duplicate submit attaches server-side.
        self.update_record(|record| {
            record.ad_analysis_attempts += 1;
            record.ad_analysis_submitted_at = Some(now_seconds());
        })
        .await?;
        self.bump("ad_analysis_submits", 1).await;
        let response = self
            .ad_analysis_post(
                ad_analysis::AD_ANALYSIS_ANALYZE_PATH,
                serde_json::to_string(&request)?,
            )
            .await;
        self.apply_ad_outcome(record, config, response).await
    }

    async fn apply_ad_outcome(
        &self,
        record: JobRecord,
        config: &AppConfig,
        response: std::result::Result<(u16, Vec<u8>), AdAnalysisCallFailure>,
    ) -> Result<()> {
        let outcome = match response {
            Ok((status, body)) => ad_analysis::classify_analyze_response(status, &body),
            Err(AdAnalysisCallFailure::BindingMissing) => {
                return self
                    .finalize_ad_phase(ad_analysis::failure_block(ad_analysis::MARKER_UNAVAILABLE))
                    .await;
            }
            Err(AdAnalysisCallFailure::Transport) => ad_analysis::AnalyzeOutcome::Retryable,
        };
        match outcome {
            ad_analysis::AnalyzeOutcome::Completed(mut success) => {
                // Invalid analyses become the failed marker — a malformed
                // block must never reach the envelope.
                let block = match self.read_result_envelope(&record.job_id).await? {
                    Some(envelope)
                        if ad_analysis::validate_analysis(
                            &mut success,
                            &envelope,
                            record.canonical_duration_seconds.unwrap_or_default(),
                        )
                        .is_ok() =>
                    {
                        ad_analysis::success_block(&success).unwrap_or_else(|_| {
                            ad_analysis::failure_block(ad_analysis::MARKER_FAILED)
                        })
                    }
                    _ => ad_analysis::failure_block(ad_analysis::MARKER_FAILED),
                };
                self.finalize_ad_phase(block).await
            }
            ad_analysis::AnalyzeOutcome::Running => {
                if record.ad_analysis_job_id.is_none() {
                    self.update_record(|record| {
                        record.ad_analysis_job_id =
                            Some(ad_analysis::ad_job_fingerprint(&record.job_id));
                    })
                    .await?;
                }
                self.schedule(Duration::from_secs(config.ad_analysis_poll_seconds))
                    .await
            }
            ad_analysis::AnalyzeOutcome::Capacity => {
                self.finalize_ad_phase(ad_analysis::failure_block(ad_analysis::MARKER_CAPACITY))
                    .await
            }
            ad_analysis::AnalyzeOutcome::Rejected => {
                self.finalize_ad_phase(ad_analysis::failure_block(ad_analysis::MARKER_FAILED))
                    .await
            }
            ad_analysis::AnalyzeOutcome::NotFound => {
                // The internal record was purged (crash window or TTL);
                // clear the poll target so the next turn resubmits, still
                // bounded by the submit-attempt cap.
                self.update_record(|record| {
                    record.ad_analysis_job_id = None;
                })
                .await?;
                self.schedule(Duration::from_secs(0)).await
            }
            ad_analysis::AnalyzeOutcome::Retryable => {
                self.schedule(Duration::from_secs(config.ad_analysis_poll_seconds))
                    .await
            }
        }
    }

    /// Merge the ad-phase outcome into the stored envelope and release the
    /// job to `result_ready` with the standard result TTL. Idempotent (an
    /// envelope already carrying `ad_analysis` is left untouched), and a
    /// raced cancel wins: only a record still in the ad phase finalizes.
    async fn finalize_ad_phase(&self, block: serde_json::Value) -> Result<()> {
        let Some(record) = self.read_record().await? else {
            return Ok(());
        };
        if record.state != job::STATE_DETECTING_ADS {
            return Ok(());
        }
        if let Some(envelope) = self.read_result_envelope(&record.job_id).await? {
            match ad_analysis::inject_ad_analysis(&envelope, &block) {
                Ok(Some(updated)) => {
                    let bucket = self.env.bucket(TRANSCRIPTION_BUCKET)?;
                    bucket
                        .put(&job::r2_result_key(&record.job_id), updated)
                        .execute()
                        .await?;
                }
                Ok(None) => {}
                Err(reason) => {
                    worker::console_error!(
                        "job {} ad analysis injection failed ({reason})",
                        record.job_id
                    );
                }
            }
        }
        let updated = self
            .update_record(|record| {
                record.state = job::STATE_RESULT_READY.to_string();
                record.state_deadline_at = Some(now_seconds() + RESULT_TTL_SECONDS);
            })
            .await?
            .expect("record existed above");
        self.sync_index(&updated).await;
        self.bump("ad_analysis_finalized", 1).await;
        self.schedule_at(updated.state_deadline_at.expect("just set"))
            .await
    }

    async fn read_result_envelope(&self, job_id: &str) -> Result<Option<Vec<u8>>> {
        self.read_chunk_audio(&job::r2_result_key(job_id)).await
    }

    async fn ad_analysis_post(
        &self,
        path: &str,
        body: String,
    ) -> std::result::Result<(u16, Vec<u8>), AdAnalysisCallFailure> {
        let service = self
            .env
            .service(ad_analysis::AD_ANALYSIS_BINDING)
            .map_err(|_| AdAnalysisCallFailure::BindingMissing)?;
        let request = internal_post(
            &format!("{}{path}", ad_analysis::AD_ANALYSIS_INTERNAL_ORIGIN),
            body,
        )
        .map_err(|_| AdAnalysisCallFailure::Transport)?;
        let mut response = service.fetch_request(request).await.map_err(|error| {
            worker::console_error!("ad analysis {path} transport error: {error:?}");
            AdAnalysisCallFailure::Transport
        })?;
        let status = response.status_code();
        let bytes = response
            .bytes()
            .await
            .map_err(|_| AdAnalysisCallFailure::Transport)?;
        Ok((status, bytes))
    }

    /// Staging-lane debugging: when the stitcher rejects a transcript, copy
    /// the model responses to `debug/<job>/` — outside `job_prefixes`, so
    /// terminal cleanup keeps them for fixture extraction. Never in the
    /// production lane: response content must not outlive its job there.
    async fn preserve_stitch_debug_responses(&self, record: &JobRecord, config: &AppConfig) {
        // LANE is validated against the known set at config time (config.rs
        // validate_lane), so this exact-string compare can no longer be
        // reached with a typo'd lane that would fail open.
        if config.lane == crate::config::LANE_PRODUCTION {
            return;
        }
        let Ok(bucket) = self.env.bucket(TRANSCRIPTION_BUCKET) else {
            return;
        };
        let mut preserved = 0u32;
        for chunk in &record.chunks {
            let key = job::r2_response_key(&record.job_id, chunk.index);
            let Ok(Some(object)) = bucket.get(&key).execute().await else {
                continue;
            };
            let Some(body) = object.body() else {
                continue;
            };
            let Ok(bytes) = body.bytes().await else {
                continue;
            };
            let debug_key = format!("debug/{}/{}.json", record.job_id, chunk.index);
            if bucket.put(&debug_key, bytes).execute().await.is_ok() {
                preserved += 1;
            }
        }
        worker::console_log!(
            "stitch debug responses preserved: job {} count {preserved}",
            record.job_id
        );
    }

    /// Retryable media failures back off (container cold starts take minutes
    /// the first time); fatal ones fail the job with the mapped stable code.
    async fn handle_media_failure(
        &self,
        record: JobRecord,
        config: &AppConfig,
        failure: media::MediaCallFailure,
    ) -> Result<()> {
        match failure {
            media::MediaCallFailure::Fatal(code) => {
                if record.reserved_seconds.is_some() {
                    self.release_and_fail(record, config, code).await?;
                } else {
                    self.finish_terminal(record, job::STATE_FAILED, code, None)
                        .await?;
                }
                Ok(())
            }
            media::MediaCallFailure::Retryable => {
                let updated = self
                    .update_record(|record| {
                        record.media_attempts += 1;
                    })
                    .await?
                    .expect("record exists");
                if updated.media_attempts >= media::MEDIA_MAX_ATTEMPTS {
                    self.release_and_fail(updated, config, types::ERROR_INTERNAL)
                        .await?;
                    return Ok(());
                }
                self.schedule(Duration::from_secs(media::MEDIA_RETRY_SECONDS))
                    .await
            }
        }
    }

    async fn release_and_fail(
        &self,
        record: JobRecord,
        config: &AppConfig,
        code: &'static str,
    ) -> Result<()> {
        let credit = self.credit(config)?;
        credit.release(&record.job_id, now_seconds()).await.ok();
        self.limiter_release(&record.job_id).await.ok();
        self.finish_terminal(record, job::STATE_FAILED, code, None)
            .await?;
        Ok(())
    }

    /// Terminal transition shared by cancel, deadline expiry, and failures:
    /// release any unsettled reservation, delete every job prefix, persist
    /// the terminal state.
    async fn finish_terminal(
        &self,
        record: JobRecord,
        terminal_state: &'static str,
        error_code: &str,
        error_message: Option<String>,
    ) -> Result<JobRecord> {
        // Content-free: job id, terminal state, and stable code only.
        worker::console_log!(
            "job {} terminal {terminal_state} code {error_code}",
            record.job_id
        );
        if let Ok(config) = self.config() {
            if let Ok(credit) = self.credit(&config) {
                credit.release(&record.job_id, now_seconds()).await.ok();
            }
        }
        self.limiter_release(&record.job_id).await.ok();

        let bucket = self.env.bucket(TRANSCRIPTION_BUCKET)?;
        // Abort an open exact-device multipart upload so its parts don't
        // linger until the one-day lifecycle backstop (explicit deletes are
        // primary). Idempotent: aborting a consumed upload is a no-op error.
        if let (Some(upload_id), false) = (record.upload_id.as_deref(), record.upload_completed) {
            if let Ok(upload) =
                bucket.resume_multipart_upload(&job::r2_upload_key(&record.job_id), upload_id)
            {
                upload.abort().await.ok();
            }
        }
        bucket
            .delete(&job::r2_result_key(&record.job_id))
            .await
            .ok();
        self.delete_job_prefixes(&record.job_id).await?;

        let error_code = error_code.to_string();
        let updated = self
            .update_record(move |record| {
                record.state = terminal_state.to_string();
                record.error_code = Some(error_code);
                if let Some(message) = error_message {
                    record.error_message = Some(message);
                }
                record.state_deadline_at = None;
                record.cleanup_complete = true;
                record.enclosure_url_ciphertext = None;
            })
            .await?
            .expect("record exists");
        self.sync_index(&updated).await;
        self.bump(
            if terminal_state == job::STATE_CANCELLED {
                "jobs_cancelled"
            } else {
                "jobs_failed"
            },
            1,
        )
        .await;
        self.state.storage().delete_alarm().await?;
        Ok(updated)
    }

    async fn delete_job_prefixes(&self, job_id: &str) -> Result<()> {
        let bucket = self.env.bucket(TRANSCRIPTION_BUCKET)?;
        for prefix in job::job_prefixes(job_id) {
            let listing = bucket.list().prefix(prefix).execute().await?;
            for object in listing.objects() {
                bucket.delete(&object.key()).await?;
            }
        }
        Ok(())
    }

    // --- Effects ---

    /// SSRF-safe streamed staging into `raw/<job>/source` with incremental
    /// SHA-256 (B5). Returns (sha256, byte_count).
    async fn stage_origin(
        &self,
        record: &JobRecord,
        config: &AppConfig,
    ) -> std::result::Result<(String, i64), &'static str> {
        let Some(ciphertext) = record.enclosure_url_ciphertext.as_deref() else {
            return Err(types::ERROR_ORIGIN_FETCH_FAILED);
        };
        let key = crate::crypto::resolve_key(
            self.env
                .secret(crate::crypto::URL_ENCRYPTION_KEY_SECRET)
                .ok()
                .map(|secret| secret.to_string())
                .as_deref(),
            config.is_development_lane(),
        )
        .map_err(|_| types::ERROR_ORIGIN_FETCH_FAILED)?;
        let url = crate::crypto::decrypt_string(ciphertext, &key)
            .map_err(|_| types::ERROR_ORIGIN_FETCH_FAILED)?;

        let started = now_seconds();
        let mut current = crate::origin::validate_origin_url(&url)
            .map_err(|_| types::ERROR_ORIGIN_FETCH_FAILED)?;
        let mut response = None;
        for _ in 0..=config.origin_fetch_max_redirects {
            let headers = Headers::new();
            headers
                .set("accept-encoding", crate::origin::MEDIA_ACCEPT_ENCODING)
                .ok();
            headers
                .set("user-agent", crate::origin::MEDIA_USER_AGENT)
                .ok();
            let mut init = RequestInit::new();
            init.with_method(Method::Get)
                .with_headers(headers)
                .with_redirect(RequestRedirect::Manual);
            let request = Request::new_with_init(current.as_str(), &init)
                .map_err(|_| types::ERROR_ORIGIN_FETCH_FAILED)?;
            let fetched = Fetch::Request(request)
                .send()
                .await
                .map_err(|_| types::ERROR_ORIGIN_FETCH_FAILED)?;
            let status = fetched.status_code();
            if (301..=308).contains(&status) {
                let Some(location) = fetched.headers().get("location").ok().flatten() else {
                    return Err(types::ERROR_ORIGIN_FETCH_FAILED);
                };
                let next = current
                    .join(&location)
                    .map_err(|_| types::ERROR_ORIGIN_FETCH_FAILED)?;
                // Every redirect revalidates against the same policy.
                current = crate::origin::validate_origin_url(next.as_str())
                    .map_err(|_| types::ERROR_ORIGIN_FETCH_FAILED)?;
                continue;
            }
            if status != 200 {
                return Err(types::ERROR_ORIGIN_FETCH_FAILED);
            }
            response = Some(fetched);
            break;
        }
        let mut response = response.ok_or(types::ERROR_ORIGIN_FETCH_FAILED)?;

        if let Ok(Some(length)) = response.headers().get("content-length") {
            if let Ok(length) = length.trim().parse::<i64>() {
                if length > config.max_source_bytes {
                    return Err(types::ERROR_SOURCE_TOO_LARGE);
                }
            }
        }

        let bucket = self
            .env
            .bucket(TRANSCRIPTION_BUCKET)
            .map_err(|_| types::ERROR_INTERNAL)?;
        let raw_key = job::r2_raw_key(&record.job_id);
        let upload = bucket
            .create_multipart_upload(&raw_key)
            .execute()
            .await
            .map_err(|_| types::ERROR_INTERNAL)?;

        let mut hasher = Sha256::new();
        let mut total: i64 = 0;
        let mut part_number: u16 = 1;
        let mut buffer: Vec<u8> = Vec::with_capacity(R2_PART_BYTES);
        let mut parts = Vec::new();
        let mut stream = response
            .stream()
            .map_err(|_| types::ERROR_ORIGIN_FETCH_FAILED)?;

        let failure = 'stream: loop {
            let chunk = match stream.next().await {
                Some(Ok(chunk)) => chunk,
                Some(Err(_)) => break Some(types::ERROR_ORIGIN_FETCH_FAILED),
                None => break None,
            };
            hasher.update(&chunk);
            total += chunk.len() as i64;
            if total > config.max_source_bytes {
                break Some(types::ERROR_SOURCE_TOO_LARGE);
            }
            if now_seconds().saturating_sub(started) > config.origin_fetch_wall_seconds as i64 {
                break Some(types::ERROR_ORIGIN_FETCH_FAILED);
            }
            buffer.extend_from_slice(&chunk);
            while let Some(data) = job::take_full_part(&mut buffer, R2_PART_BYTES) {
                match upload.upload_part(part_number, data).await {
                    Ok(part) => parts.push(part),
                    Err(_) => break 'stream Some(types::ERROR_INTERNAL),
                }
                part_number += 1;
            }
        };

        if let Some(code) = failure {
            upload.abort().await.ok();
            return Err(code);
        }
        if !buffer.is_empty() || parts.is_empty() {
            match upload.upload_part(part_number, buffer).await {
                Ok(part) => parts.push(part),
                Err(_) => {
                    upload.abort().await.ok();
                    return Err(types::ERROR_INTERNAL);
                }
            }
        }
        // complete() consumes the multipart handle, so capture the id first:
        // on failure the still-open upload must be aborted like every other
        // exit does, or up to 512 MiB of parts linger until the 24 h
        // lifecycle backstop (and trip the orphan-sweeper alert). The id is
        // never persisted, so resume-by-id here is the only chance (RTW-6).
        let upload_id = upload.upload_id().await;
        if let Err(_error) = upload.complete(parts).await {
            if let Ok(resumed) = bucket.resume_multipart_upload(&raw_key, upload_id) {
                resumed.abort().await.ok();
            }
            return Err(types::ERROR_INTERNAL);
        }
        if total == 0 {
            bucket.delete(&raw_key).await.ok();
            return Err(types::ERROR_ORIGIN_FETCH_FAILED);
        }
        Ok((hex::encode(hasher.finalize()), total))
    }

    async fn run_media_probe(
        &self,
        record: &JobRecord,
        config: &AppConfig,
    ) -> std::result::Result<MediaProbeResponse, media::MediaCallFailure> {
        if self.fake_media_enabled(config) {
            // Honest fake: recompute identity from the actual stored source
            // object, exactly like the container does — so upload-identity
            // verification is real in workerd tests.
            let bucket = self
                .env
                .bucket(TRANSCRIPTION_BUCKET)
                .map_err(|_| media::MediaCallFailure::Retryable)?;
            let object = bucket
                .get(&record.source_object_key())
                .execute()
                .await
                .map_err(|_| media::MediaCallFailure::Retryable)?
                .ok_or(media::MediaCallFailure::Retryable)?;
            let body = object.body().ok_or(media::MediaCallFailure::Retryable)?;
            let bytes = body
                .bytes()
                .await
                .map_err(|_| media::MediaCallFailure::Retryable)?;
            let duration = record
                .device_identity
                .as_ref()
                .and_then(|device| device.duration_seconds)
                .or(record.declared_duration_seconds)
                .unwrap_or(600.0);
            return Ok(MediaProbeResponse {
                duration_seconds: duration,
                codec: "mp3".to_string(),
                audio_stream_count: 1,
                byte_count: bytes.len() as i64,
                sha256: hex::encode(Sha256::digest(&bytes)),
            });
        }
        let request = MediaProbeRequest {
            job_id: record.job_id.clone(),
            source_key: record.source_object_key(),
        };
        self.media_post(MEDIA_PROBE_PATH, &request).await
    }

    async fn run_media_chunk(
        &self,
        record: &JobRecord,
        config: &AppConfig,
    ) -> std::result::Result<MediaChunkResponse, media::MediaCallFailure> {
        if self.fake_media_enabled(config) {
            return self
                .fake_media_chunks(record)
                .await
                .map_err(media::MediaCallFailure::Fatal);
        }
        let request = MediaChunkRequest {
            job_id: record.job_id.clone(),
            source_key: record.source_object_key(),
            chunk_prefix: job::r2_chunk_prefix(&record.job_id),
            chunk_seconds: job::CHUNK_SECONDS,
            overlap_seconds: job::OVERLAP_SECONDS,
            max_chunk_raw_bytes: job::MAX_CHUNK_RAW_BYTES,
        };
        self.media_post(MEDIA_CHUNK_PATH, &request).await
    }

    fn fake_media_enabled(&self, config: &AppConfig) -> bool {
        config.is_development_lane()
            && self
                .env
                .var("FAKE_MEDIA")
                .map(|value| value.to_string() == "true")
                .unwrap_or(false)
    }

    fn fake_ai_enabled(&self, config: &AppConfig) -> bool {
        config.is_development_lane()
            && self
                .env
                .var("FAKE_AI")
                .map(|value| value.to_string() == "true")
                .unwrap_or(false)
    }

    /// Development-lane fake media path for workerd integration tests: splits
    /// the staged raw object into byte slices shaped like the chunk contract.
    async fn fake_media_chunks(
        &self,
        record: &JobRecord,
    ) -> std::result::Result<MediaChunkResponse, &'static str> {
        let bucket = self
            .env
            .bucket(TRANSCRIPTION_BUCKET)
            .map_err(|_| types::ERROR_INTERNAL)?;
        let raw = bucket
            .get(&record.source_object_key())
            .execute()
            .await
            .map_err(|_| types::ERROR_INTERNAL)?
            .ok_or(types::ERROR_INTERNAL)?;
        let body = raw.body().ok_or(types::ERROR_INTERNAL)?;
        let bytes = body.bytes().await.map_err(|_| types::ERROR_INTERNAL)?;

        let duration = record
            .device_identity
            .as_ref()
            .and_then(|identity| identity.duration_seconds)
            .or(record.declared_duration_seconds)
            .unwrap_or(600.0);
        let chunk_count = ((duration / job::STEP_SECONDS).ceil() as usize).max(1);
        let slice_size = bytes.len().div_ceil(chunk_count);
        let mut chunks = Vec::with_capacity(chunk_count);
        let mut manifest_hasher = Sha256::new();
        // `mlat` hook: pace chunk writes so workerd tests can observe the
        // overlap driver transcribing while chunking is still in progress.
        let media_latency_ms =
            ai::parse_fake_hooks(record.language_code.as_deref()).media_chunk_latency_ms;
        for index in 0..chunk_count {
            if let Some(latency_ms) = media_latency_ms {
                worker::Delay::from(Duration::from_millis(latency_ms)).await;
            }
            let start = index * slice_size;
            let end = ((index + 1) * slice_size).min(bytes.len());
            let slice = &bytes[start.min(bytes.len())..end];
            let key = format!("{}{}.mp3", job::r2_chunk_prefix(&record.job_id), index);
            bucket
                .put(&key, slice.to_vec())
                .execute()
                .await
                .map_err(|_| types::ERROR_INTERNAL)?;
            let sha256 = hex::encode(Sha256::digest(slice));
            manifest_hasher.update(sha256.as_bytes());
            let requested_start = index as f64 * job::STEP_SECONDS;
            let actual = (duration - requested_start)
                .min(job::CHUNK_SECONDS)
                .max(1.0);
            chunks.push(media::MediaChunkEntry {
                index: index as u32,
                key,
                requested_start_seconds: requested_start,
                requested_duration_seconds: job::CHUNK_SECONDS,
                actual_duration_seconds: actual,
                byte_count: slice.len() as i64,
                sha256,
            });
        }
        Ok(MediaChunkResponse {
            chunks,
            manifest_sha256: hex::encode(manifest_hasher.finalize()),
            chunk_audio_profile: Some("mp3-stream-copy-v1".to_string()),
        })
    }

    /// Best-effort container wake (A3). Errors are logged and ignored: the
    /// staging path already tolerates cold starts with retryable backoff.
    async fn media_wake(&self) {
        let Ok(service) = self.env.service(MEDIA_BINDING) else {
            return;
        };
        let Ok(request) = internal_post(
            &format!("{MEDIA_INTERNAL_ORIGIN}{MEDIA_WAKE_PATH}"),
            "{}".to_string(),
        ) else {
            return;
        };
        if let Err(error) = service.fetch_request(request).await {
            worker::console_error!("media wake ping failed (ignored): {error:?}");
        }
    }

    async fn media_post<T: serde::Serialize, R: for<'de> serde::Deserialize<'de>>(
        &self,
        path: &str,
        body: &T,
    ) -> std::result::Result<R, media::MediaCallFailure> {
        let service = self
            .env
            .service(MEDIA_BINDING)
            .map_err(|_| media::MediaCallFailure::Fatal(types::ERROR_INTERNAL))?;
        let headers = Headers::new();
        headers.set("content-type", JSON_CONTENT_TYPE).ok();
        let mut init = RequestInit::new();
        init.with_method(Method::Post)
            .with_headers(headers)
            .with_body(Some(
                serde_json::to_string(body)
                    .map_err(|_| media::MediaCallFailure::Fatal(types::ERROR_INTERNAL))?
                    .into(),
            ));
        let request = Request::new_with_init(&format!("{MEDIA_INTERNAL_ORIGIN}{path}"), &init)
            .map_err(|_| media::MediaCallFailure::Fatal(types::ERROR_INTERNAL))?;
        let mut response = service.fetch_request(request).await.map_err(|error| {
            worker::console_error!("media {path} transport error: {error:?}");
            media::MediaCallFailure::Retryable
        })?;
        let status = response.status_code();
        if status != 200 {
            worker::console_error!("media {path} status {status}");
        }
        if status != 200 {
            let error_code = response
                .json::<ErrorResponse>()
                .await
                .ok()
                .map(|body| body.error);
            return Err(media::classify_media_failure(status, error_code.as_deref()));
        }
        response
            .json()
            .await
            .map_err(|_| media::MediaCallFailure::Retryable)
    }

    async fn run_ai(
        &self,
        record: &JobRecord,
        config: &AppConfig,
        audio: &[u8],
        chunk_index: u32,
        prior_failed_attempts: u32,
    ) -> std::result::Result<Vec<u8>, String> {
        if self.fake_ai_enabled(config) {
            // Test hooks (development lane, FAKE_AI only) carried in the
            // language code: per-call latency (proves wave overlap in
            // workerd), targeted per-chunk failures, and the legacy
            // "fake-fail:<message>" first-attempt-of-chunk-0 form.
            let hooks = ai::parse_fake_hooks(record.language_code.as_deref());
            if let Some(latency_ms) = hooks.latency_ms {
                worker::Delay::from(Duration::from_millis(latency_ms)).await;
            }
            if let Some(rule) = &hooks.failure {
                if rule.applies(chunk_index, prior_failed_attempts) {
                    return Err(ai::sanitize_ai_error(&rule.message));
                }
            }
            let duration = record
                .chunks
                .get(chunk_index as usize)
                .map(|chunk| chunk.actual_duration_seconds)
                .unwrap_or(300.0);
            let response = ai::fake_whisper_response(chunk_index, duration);
            return serde_json::to_vec(&response).map_err(|error| error.to_string());
        }

        let encoded = base64::engine::general_purpose::STANDARD.encode(audio);
        let request = ai::WhisperRequest::transcribe(encoded, record.language_code.clone());
        let ai_binding = self
            .env
            .ai("AI")
            .map_err(|error| ai::sanitize_ai_error(&error.to_string()))?;
        let value: serde_json::Value = ai_binding
            .run(&config.model, &request)
            .await
            .map_err(|error| ai::sanitize_ai_error(&format!("{error:?}")))?;
        // Persist the raw response bytes; decode is validated at stitch time.
        serde_json::to_vec(&value).map_err(|error| error.to_string())
    }

    async fn limiter_admit(
        &self,
        record: &JobRecord,
        audio_seconds: f64,
        config: &AppConfig,
    ) -> Result<LimiterOutcome> {
        let namespace = self.env.durable_object(USAGE_LIMITER_BINDING)?;
        let stub = namespace.get_by_name(GLOBAL_LIMITER_OBJECT)?;
        let body = serde_json::to_string(&LimiterAdmitRequest {
            job_id: record.job_id.clone(),
            audio_seconds,
            daily_cap_micro_usd: config.daily_spend_cap_usd_micro,
            max_slots: config.global_inference_concurrency,
            remaining_seconds: eta::self_remaining_seconds(
                record,
                self.chunk_concurrency(record, config),
                now_seconds(),
            ),
            default_remaining_seconds: config.queue_default_remaining_seconds,
        })?;
        let request = internal_post(
            &format!("{LIMITER_INTERNAL_ORIGIN}{LIMITER_ADMIT_PATH}"),
            body,
        )?;
        let mut response = stub.fetch_with_request(request).await?;
        Ok(match response.status_code() {
            200 => LimiterOutcome::Admitted,
            429 => LimiterOutcome::SpendCapped,
            409 => {
                let body = response.text().await.unwrap_or_default();
                let busy: LimiterBusyResponse =
                    serde_json::from_str(&body).unwrap_or(LimiterBusyResponse {
                        queue_position: 1,
                        wait_seconds: config.queue_default_remaining_seconds,
                    });
                LimiterOutcome::Busy {
                    queue_position: busy.queue_position,
                    wait_seconds: busy.wait_seconds,
                }
            }
            status => {
                return Err(worker::Error::RustError(format!(
                    "limiter admit unexpected status {status}"
                )))
            }
        })
    }

    async fn record_queue_denial(&self, queue_position: u32, wait_seconds: u32) -> Result<()> {
        self.update_record(|record| {
            record.queued_since.get_or_insert_with(now_seconds);
            record.queue_position = Some(queue_position);
            record.queue_wait_seconds = Some(wait_seconds);
        })
        .await?;
        Ok(())
    }

    async fn clear_queue_state(&self, record: &JobRecord) -> Result<()> {
        if record.queued_since.is_none()
            && record.queue_position.is_none()
            && record.queue_wait_seconds.is_none()
        {
            return Ok(());
        }
        self.update_record(|record| {
            record.queued_since = None;
            record.queue_position = None;
            record.queue_wait_seconds = None;
        })
        .await?;
        Ok(())
    }

    async fn limiter_release(&self, job_id: &str) -> Result<()> {
        let namespace = self.env.durable_object(USAGE_LIMITER_BINDING)?;
        let stub = namespace.get_by_name(GLOBAL_LIMITER_OBJECT)?;
        let body = serde_json::to_string(&LimiterReleaseRequest {
            job_id: job_id.to_string(),
        })?;
        let request = internal_post(
            &format!("{LIMITER_INTERNAL_ORIGIN}{LIMITER_RELEASE_PATH}"),
            body,
        )?;
        stub.fetch_with_request(request).await?;
        Ok(())
    }

    fn status_response(&self, record: &JobRecord, balance: Option<Balance>) -> Result<Response> {
        let config = self.config().ok();
        let include_phase_timestamps = config.as_ref().is_some_and(AppConfig::is_development_lane);
        let chunk_concurrency = config
            .as_ref()
            .map(|config| self.chunk_concurrency(record, config))
            .unwrap_or(4);
        let response = types::JobResponse {
            schema_version: SCHEMA_VERSION,
            job: job_status(
                record,
                include_phase_timestamps,
                chunk_concurrency,
                now_seconds(),
            ),
            balance,
        };
        json_success(200, &response)
    }
}

/// Ad-analysis service-binding call failures. A missing binding is the
/// unavailable marker (misdeployed lane must not burn the phase deadline);
/// transport hiccups retry on the alarm loop.
enum AdAnalysisCallFailure {
    BindingMissing,
    Transport,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LimiterOutcome {
    Admitted,
    Busy {
        queue_position: u32,
        wait_seconds: u32,
    },
    SpendCapped,
}

/// What the overlap stage hands back to `step_chunk`: the authoritative
/// media result plus any fatal chunk outcome observed mid-overlap.
struct OverlapReport {
    media: std::result::Result<MediaChunkResponse, media::MediaCallFailure>,
    fatal: Option<&'static str>,
    defer_seconds: Option<u64>,
}

/// Mutate the chunk-work entry for `index`, creating it if the overlap
/// driver touches a chunk before the manifest sizes `chunk_work`.
fn upsert_chunk_work<F>(record: &mut JobRecord, index: u32, mutate: F)
where
    F: FnOnce(&mut job::ChunkWork),
{
    if let Some(work) = record
        .chunk_work
        .iter_mut()
        .find(|work| work.index == index)
    {
        mutate(work);
        return;
    }
    let mut work = job::init_chunk_work(1, 0).remove(0);
    work.index = index;
    mutate(&mut work);
    record.chunk_work.push(work);
}

/// One chunk future's report back to the wave driver. Timing fields are
/// epoch seconds measured around the AI call itself (zero when no call ran).
struct ChunkOutcome {
    index: u32,
    attempt_seconds: f64,
    ai_started_at: i64,
    ai_ended_at: i64,
    result: ChunkCallResult,
}

enum ChunkCallResult {
    Success,
    /// The chunk's response object already exists (a previous turn's work
    /// landed without its record write): count it done, no new spend.
    AlreadyTranscribed,
    MissingChunkObject,
    /// Limiter/R2 transport hiccup: the chunk stays pending, no attempt is
    /// burned, and the turn ends with the pass-0 60 s alarm retry pacing.
    TransportError,
    AiError {
        sanitized: String,
        class: AiFailureClass,
    },
}

pub fn job_status(
    record: &JobRecord,
    include_phase_timestamps: bool,
    chunk_concurrency: u32,
    now: i64,
) -> JobStatus {
    let chunk_progress = eta::chunk_progress(record);
    let estimate = eta::project(record, chunk_concurrency, now);
    let progress = if chunk_progress.is_none() && estimate.is_none() {
        None
    } else {
        Some(JobProgress {
            chunks_completed: chunk_progress.map(|(completed, _)| completed),
            chunks_total: chunk_progress.map(|(_, total)| total),
            estimated_remaining_seconds: estimate.and_then(|value| value.remaining_seconds),
            estimate_status: estimate.map(|value| value.status),
        })
    };
    let phase_timestamps = include_phase_timestamps.then(|| types::PhaseTimestamps {
        states: record.phase_timestamps.clone(),
        chunks: record
            .chunk_work
            .iter()
            .map(|work| types::ChunkAiSpan {
                index: work.index,
                ai_started_at: work.ai_started_at,
                ai_ended_at: work.ai_ended_at,
                failed_attempts: work.failed_attempts,
            })
            .collect(),
    });
    JobStatus {
        job_id: record.job_id.clone(),
        state: record.state.clone(),
        ad_analysis_requested: record.ad_analysis_requested,
        episode_id: Some(record.episode_id.clone()),
        progress,
        error: record.error_code.as_ref().map(|code| JobError {
            code: code.clone(),
            message: record.error_message.clone(),
        }),
        created_at: Some(job::iso8601(record.created_at)),
        updated_at: Some(job::iso8601(record.updated_at)),
        phase_timestamps,
    }
}

fn internal_post(url: &str, body: String) -> Result<Request> {
    let headers = Headers::new();
    headers.set("content-type", JSON_CONTENT_TYPE)?;
    let mut init = RequestInit::new();
    init.with_method(Method::Post)
        .with_headers(headers)
        .with_body(Some(body.into()));
    Request::new_with_init(url, &init)
}

fn json_error(status: u16, code: &str) -> Result<Response> {
    json_success(status, &ErrorResponse::new(code))
}

fn json_error_body(status: u16, body: ErrorResponse) -> Result<Response> {
    json_success(status, &body)
}

fn json_success(status: u16, body: &impl serde::Serialize) -> Result<Response> {
    let headers = Headers::new();
    headers.set("content-type", JSON_CONTENT_TYPE)?;
    Ok(Response::builder()
        .with_status(status)
        .with_headers(headers)
        .fixed(serde_json::to_vec(body)?))
}

fn now_seconds() -> i64 {
    (Date::now().as_millis() / 1_000)
        .try_into()
        .unwrap_or(i64::MAX)
}

// The usage limiter Durable Object lives here so both DO classes are wasm-only.
//
// State lives in the DO's synchronous SQLite storage: concurrent admits from
// several job DOs interleave across `await` points in the wasm event loop
// (input gates do not cover the read-modify-write here), so the read → admit
// → write section must be free of awaits to stay atomic. Every await (body
// parse, one-time legacy migration) happens BEFORE the critical section.
#[durable_object(fetch)]
pub struct TranscriptionUsageLimiter {
    state: State,
}

const LIMITER_TABLE_DDL: &str = "CREATE TABLE IF NOT EXISTS limiter_state (\
     id INTEGER PRIMARY KEY CHECK (id = 1), payload TEXT NOT NULL)";

impl DurableObject for TranscriptionUsageLimiter {
    fn new(state: State, _env: Env) -> Self {
        Self { state }
    }

    async fn fetch(&self, mut req: Request) -> Result<Response> {
        if req.method() != Method::Post {
            return json_error(405, "method_not_allowed");
        }
        let path = req.path();
        // Parse before touching state so the section below stays await-free.
        let body = req.text().await?;
        let sql = self.state.storage().sql();
        sql.exec(LIMITER_TABLE_DDL, None)?;
        if read_limiter_row(&sql)?.is_none() {
            self.migrate_legacy_limiter_state(&sql).await?;
        }

        match path.as_str() {
            LIMITER_ADMIT_PATH => {
                let admit_request: LimiterAdmitRequest = match serde_json::from_str(&body) {
                    Ok(request) => request,
                    Err(_) => return json_error(400, types::ERROR_INVALID_REQUEST),
                };
                let day_index = (Date::now().as_millis() / 86_400_000) as i64;
                // Atomic: synchronous read, decide, synchronous write.
                let current = read_limiter_row(&sql)?.unwrap_or_default();
                let (next, decision) =
                    crate::limiter::admit(&current, &admit_request, day_index, now_seconds());
                match decision {
                    crate::limiter::AdmitDecision::Admit { spend_micro_usd } => {
                        write_limiter_row(&sql, &next)?;
                        json_success(
                            200,
                            &serde_json::json!({ "spend_micro_usd": spend_micro_usd }),
                        )
                    }
                    crate::limiter::AdmitDecision::Busy {
                        queue_position,
                        wait_seconds,
                    } => {
                        // Tickets are part of the admission decision, so a
                        // denial must persist the returned state atomically.
                        write_limiter_row(&sql, &next)?;
                        json_success(
                            409,
                            &LimiterBusyResponse {
                                queue_position,
                                wait_seconds,
                            },
                        )
                    }
                    crate::limiter::AdmitDecision::SpendCapped => {
                        write_limiter_row(&sql, &next)?;
                        json_error(429, types::ERROR_RATE_LIMITED)
                    }
                }
            }
            LIMITER_RELEASE_PATH => {
                let release_request: LimiterReleaseRequest = match serde_json::from_str(&body) {
                    Ok(request) => request,
                    Err(_) => return json_error(400, types::ERROR_INVALID_REQUEST),
                };
                let current = read_limiter_row(&sql)?.unwrap_or_default();
                let next = crate::limiter::release(&current, &release_request.job_id);
                write_limiter_row(&sql, &next)?;
                json_success(200, &serde_json::json!({ "message": "released" }))
            }
            _ => json_error(404, "not_found"),
        }
    }
}

impl TranscriptionUsageLimiter {
    /// One-time move of the pass-0 KV-style state into the SQL row so a
    /// deploy loses neither the active slot nor the day's spend. Idempotent
    /// under interleaving: the row is re-checked after the await and every
    /// racer migrates the same legacy value.
    async fn migrate_legacy_limiter_state(&self, sql: &worker::SqlStorage) -> Result<()> {
        let storage = self.state.storage();
        let legacy = match storage.get::<String>("limiter").await? {
            Some(raw) => decode_limiter_state(&raw)?,
            None => crate::limiter::LimiterState::default(),
        };
        if read_limiter_row(sql)?.is_some() {
            return Ok(());
        }
        write_limiter_row(sql, &legacy)
    }
}

#[derive(serde::Deserialize)]
struct LimiterPayloadRow {
    payload: String,
}

fn read_limiter_row(sql: &worker::SqlStorage) -> Result<Option<crate::limiter::LimiterState>> {
    let rows: Vec<LimiterPayloadRow> = sql
        .exec("SELECT payload FROM limiter_state WHERE id = 1", None)?
        .to_array()?;
    match rows.into_iter().next() {
        Some(row) => decode_limiter_state(&row.payload).map(Some),
        None => Ok(None),
    }
}

fn decode_limiter_state(payload: &str) -> Result<crate::limiter::LimiterState> {
    crate::limiter::decode_state(payload).map_err(|_| {
        worker::console_error!("limiter state decode failure");
        worker::Error::RustError("limiter state decode failure".to_string())
    })
}

fn write_limiter_row(sql: &worker::SqlStorage, state: &crate::limiter::LimiterState) -> Result<()> {
    sql.exec(
        "INSERT INTO limiter_state (id, payload) VALUES (1, ?) \
         ON CONFLICT(id) DO UPDATE SET payload = excluded.payload",
        vec![worker::SqlStorageValue::String(serde_json::to_string(
            state,
        )?)],
    )?;
    Ok(())
}
