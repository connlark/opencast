use std::cell::Cell;
use std::rc::Rc;
use std::time::Duration;

use worker::{
    console_error, durable_object, wasm_bindgen, Date, Delay, DurableObject, Env, Headers, Method,
    Request, Response, Result, State, Storage,
};

use crate::analysis::run_analysis;
use crate::billing::{
    billing_retry_delay_seconds, BillingContext, JobBillingState, PendingBillingAction,
    BILLING_MAX_ATTEMPTS, ERROR_BILLING_UNAVAILABLE,
};
use crate::credit::CreditError;
use crate::job::{
    alarm_decision, poll_decision, submit_decision, terminal_billing_action,
    transcript_content_hash, AlarmDecision, JobDoPollRequest, JobRecord, JobSubmitRequest,
    PollDecision, SubmitDecision, JOB_HEARTBEAT_SECONDS, JOB_POLL_AFTER_SECONDS,
    JOB_RESULT_TTL_SECONDS, JOB_SUBMIT_POLL_AFTER_SECONDS,
};
use crate::route::JSON_CONTENT_TYPE;
use crate::types::{resolve_gemini_model, ErrorResponse, GEMINI_MODEL_ENV_VAR};
use crate::worker_app::{admit_spend_caps, mint_billing_id, reserve_failure_response, AppConfig};

const JOB_STORAGE_KEY: &str = "job";
const GEMINI_API_KEY: &str = "GEMINI_API_KEY";
const INTERNAL_SUBMIT_PATH: &str = "/submit";
const INTERNAL_POLL_PATH: &str = "/poll";

#[durable_object(alarm)]
pub struct TranscriptAnalysisJob {
    state: Rc<State>,
    env: Env,
    run_active: Cell<bool>,
    admission_active: Cell<bool>,
}

impl DurableObject for TranscriptAnalysisJob {
    fn new(state: State, env: Env) -> Self {
        Self {
            state: Rc::new(state),
            env,
            run_active: Cell::new(false),
            admission_active: Cell::new(false),
        }
    }

    async fn fetch(&self, mut req: Request) -> Result<Response> {
        if req.method() != Method::Post {
            return json_error(405, "method_not_allowed");
        }

        match req.path().as_str() {
            INTERNAL_SUBMIT_PATH => self.handle_submit(&mut req).await,
            INTERNAL_POLL_PATH => self.handle_poll(&mut req).await,
            _ => json_error(404, "not_found"),
        }
    }

    async fn alarm(&self) -> Result<Response> {
        let record = read_record(&self.state.storage()).await?;
        match alarm_decision(record.as_ref(), self.run_active.get(), now_seconds()) {
            AlarmDecision::Purge => self.purge_with_final_billing().await?,
            AlarmDecision::Heartbeat => {
                self.state
                    .storage()
                    .set_alarm(Duration::from_secs(JOB_HEARTBEAT_SECONDS))
                    .await?;
            }
            AlarmDecision::SchedulePurge { purge_at } => {
                set_alarm_at(&self.state.storage(), purge_at).await?;
            }
            AlarmDecision::FailTransient { record } => {
                let JobRecord::FailedTransient { purge_at, .. } = &record else {
                    unreachable!("alarm watchdog always creates a transient failure")
                };
                // The watchdogged run's reservation is released through the
                // shared terminal-billing path (pending + bounded retries).
                apply_terminal_billing(&self.env, &self.state.storage(), record.clone(), *purge_at)
                    .await?;
            }
            AlarmDecision::RetryBilling => self.retry_pending_billing().await?,
        }
        Response::ok("")
    }
}

impl TranscriptAnalysisJob {
    async fn handle_submit(&self, req: &mut Request) -> Result<Response> {
        let submit = match req.json::<JobSubmitRequest>().await {
            Ok(submit) => submit,
            Err(_) => return json_error(400, "malformed_json"),
        };
        let submitted_hash =
            transcript_content_hash(&submit.request.transcript, &submit.request.segments);

        loop {
            let mut record = read_record(&self.state.storage()).await?;
            match submit_decision(record.as_ref(), &submit.subject, &submitted_hash) {
                SubmitDecision::Attach { job_id, join } => {
                    if join {
                        if let Some(record) = record.as_mut() {
                            if record.push_subject(&submit.subject) {
                                write_record(&self.state.storage(), record).await?;
                            }
                        }
                    }
                    return job_status(202, &job_id, "running", JOB_SUBMIT_POLL_AFTER_SECONDS);
                }
                SubmitDecision::ServeCompleted {
                    result_json, join, ..
                } => {
                    // Completed results serve idempotently until the TTL
                    // alarm purges them: a response lost in transit must be
                    // recoverable by asking again, never by re-running the
                    // model. A content-proven new subject joins first so its
                    // later polls stay authorized.
                    if join {
                        if let Some(record) = record.as_mut() {
                            if record.push_subject(&submit.subject) {
                                write_record(&self.state.storage(), record).await?;
                            }
                        }
                    }
                    return raw_json(200, result_json);
                }
                SubmitDecision::DenyContentMismatch => {
                    return json_error(409, "fingerprint_content_mismatch");
                }
                SubmitDecision::Start => {}
            }

            // The record being replaced may still carry an unresolved
            // settle/release (the credit backend was down at terminal time).
            // A billed restart fails closed: its own reserve needs the same
            // backend, and refusing preserves the pending action's full
            // alarm retry budget. An unbilled restart (billing since flipped
            // dark) resolves the action inline — once, loudly on failure —
            // so the overwrite below can never strand it silently.
            if let Some((billing_id, action)) = pending_billing(record.as_ref()) {
                if submit.billing.is_some() {
                    return json_error(503, ERROR_BILLING_UNAVAILABLE);
                }
                if !attempt_billing_action(&self.env, &billing_id, action).await {
                    console_error!(
                        "transcript-analysis billing {action:?} abandoned by unbilled restart: {billing_id}"
                    );
                }
                if let Some(mut current) =
                    reread_matching_terminal(&self.state.storage(), &billing_id).await?
                {
                    if let Some(billing) = current.billing_mut() {
                        billing.pending = None;
                    }
                    write_record(&self.state.storage(), &current).await?;
                }
                continue;
            }

            // Non-storage I/O opens the DO input gate. Serialize the
            // admission+reserve window in memory so concurrent identical
            // submits cannot double-consume quota or double-reserve before
            // the Running record is persisted. The window's Drop releases it
            // on every exit path, error propagation included.
            let Some(_admission_window) = ActiveWindow::acquire(&self.admission_active) else {
                Delay::from(Duration::from_millis(10)).await;
                continue;
            };
            if let Some(response) = admit_spend_caps(
                &self.env,
                &submit.usage_object_name,
                submit.usage_profile,
                day_index(),
                submit.estimated_input_tokens,
            )
            .await?
            {
                return Ok(response);
            }

            // Reserve under a FRESH `tan-` billing id per run attempt —
            // never the fingerprint: PurchaseWorker's
            // reserve idempotency key is permanent and this DO restarts
            // failed jobs under the same fingerprint. Denied reserves have
            // already consumed admission quota.
            let mut billing_state: Option<JobBillingState> = None;
            if let Some(context) = &submit.billing {
                match reserve_billing(&self.env, context).await {
                    Ok(Ok(state)) => billing_state = Some(state),
                    Ok(Err(response)) => return Ok(response),
                    Err(error) => {
                        // Billing-required lanes fail CLOSED when the credit
                        // backend is unreachable — loudly:
                        // flip-day misconfiguration must be diagnosable from
                        // the logs, not bisected from bare 503s.
                        console_error!(
                            "transcript-analysis billing unavailable at reserve: {error}"
                        );
                        return json_error(503, ERROR_BILLING_UNAVAILABLE);
                    }
                }
            }

            let job_id = submit.request.transcript.fingerprint.clone();
            let started_at = now_seconds();
            let subjects = if submit.subject.is_empty() {
                Vec::new()
            } else {
                vec![submit.subject.clone()]
            };
            let running = JobRecord::Running {
                job_id: job_id.clone(),
                started_at,
                subjects,
                content_hash: submitted_hash.clone(),
                billing: billing_state,
            };
            // A reservation is at stake past the reserve: a storage failure
            // here would leave the hold referenced by nothing — no record,
            // no retry path, and no expiry on PurchaseWorker's side. Best
            // effort release (and a log naming the id) before propagating.
            let persisted: Result<()> = async {
                write_record(&self.state.storage(), &running).await?;
                self.state
                    .storage()
                    .set_alarm(Duration::from_secs(JOB_HEARTBEAT_SECONDS))
                    .await
            }
            .await;
            if let Err(error) = persisted {
                if let Some(billing) = running.billing() {
                    let released = attempt_billing_action(
                        &self.env,
                        &billing.billing_id,
                        PendingBillingAction::Release,
                    )
                    .await;
                    console_error!(
                        "transcript-analysis reservation {} after failed submit persist: {}",
                        if released { "released" } else { "STRANDED" },
                        billing.billing_id
                    );
                }
                return Err(error);
            }
            self.run_active.set(true);

            let state = self.state.clone();
            let env = self.env.clone();
            let request = submit.request;
            let response_job_id = job_id.clone();
            let recovery_state = self.state.clone();
            let recovery_env = self.env.clone();
            let recovery_job_id = job_id.clone();
            worker::wasm_bindgen_futures::spawn_local(async move {
                if let Err(error) = run_job(state, env, job_id, started_at, request).await {
                    console_error!("Transcript-analysis job task failed: {error:?}");
                    // A paid model call whose bookkeeping failed (for example
                    // the terminal record write) must not leave the record
                    // Running until the 600-second deadline.
                    // Best-effort: the failure record is small, so this write
                    // succeeds even when the completed record's did not.
                    if let Err(recovery_error) = terminalize_failed_run(
                        &recovery_state,
                        &recovery_env,
                        &recovery_job_id,
                        started_at,
                    )
                    .await
                    {
                        console_error!(
                            "Transcript-analysis failed-run terminalization failed: {recovery_error:?}"
                        );
                    }
                }
            });

            return job_status(
                202,
                &response_job_id,
                "running",
                JOB_SUBMIT_POLL_AFTER_SECONDS,
            );
        }
    }

    async fn handle_poll(&self, req: &mut Request) -> Result<Response> {
        let poll = match req.json::<JobDoPollRequest>().await {
            Ok(poll) => poll,
            Err(_) => return json_error(400, "malformed_json"),
        };
        let record = read_record(&self.state.storage()).await?;
        match poll_decision(record.as_ref(), poll.subject.as_deref()) {
            PollDecision::NotFound => json_error(404, "job_not_found"),
            PollDecision::Running { job_id } => {
                job_status(202, &job_id, "running", JOB_POLL_AFTER_SECONDS)
            }
            // Success is served idempotently until the TTL purge (a lost
            // response re-polls). Failures purge as they serve: nothing of
            // value is lost with them, and the purge is what lets a caller's
            // resubmit start a fresh run instead of re-reading a dead record.
            PollDecision::ServeCompleted { result_json, .. } => raw_json(200, result_json),
            PollDecision::ServeFailedUpstream { status, code } => {
                self.purge_served_failure(record.as_ref()).await?;
                json_error_owned(status, code)
            }
            PollDecision::ServeFailedTransient => {
                self.purge_served_failure(record.as_ref()).await?;
                json_error(503, "job_failed_transient")
            }
        }
    }

    async fn purge(&self) -> Result<()> {
        self.state.storage().delete_all().await?;
        self.state.storage().delete_alarm().await
    }

    /// Purge behind a served failure — EXCEPT while its settle/release is
    /// still unresolved: purging then would truncate the bounded alarm
    /// retries and strand the hold (PurchaseWorker has no reservation
    /// expiry). Such records purge on their TTL alarm instead; this path is
    /// storage-only, so nothing can interleave between decision and purge.
    async fn purge_served_failure(&self, record: Option<&JobRecord>) -> Result<()> {
        if record
            .and_then(JobRecord::billing)
            .is_some_and(|billing| billing.pending.is_some())
        {
            return Ok(());
        }
        self.purge().await
    }

    /// Purge at the TTL deadline, but never silently drop an unresolved
    /// settle/release with the record: one final attempt, then a loud
    /// abandonment (operator signal).
    async fn purge_with_final_billing(&self) -> Result<()> {
        let Some(record) = read_record(&self.state.storage()).await? else {
            return self.purge().await;
        };
        if let Some((billing_id, action)) = pending_billing(Some(&record)) {
            if !attempt_billing_action(&self.env, &billing_id, action).await {
                console_error!(
                    "transcript-analysis billing {action:?} abandoned at purge: {billing_id}"
                );
                release_abandoned_settle(&self.env, &billing_id, action).await;
            }
            // The attempts above opened the input gate: an interleaved
            // submit may own a fresh run (record, reservation, heartbeat
            // alarm) — purge only the exact record this pass read.
            if read_record(&self.state.storage()).await?.as_ref() != Some(&record) {
                return Ok(());
            }
        }
        self.purge().await
    }

    /// Bounded post-terminal repair: the terminal-path
    /// attempt plus alarm retries up to `BILLING_MAX_ATTEMPTS`, paced by
    /// `billing_retry_delay_seconds`, abandoning loudly through the shared
    /// attempt path.
    async fn retry_pending_billing(&self) -> Result<()> {
        let storage = self.state.storage();
        let Some(record) = read_record(&storage).await? else {
            return self.purge().await;
        };
        let Some(purge_at) = record.purge_at() else {
            return Ok(());
        };
        let Some((billing_id, action)) = pending_billing(Some(&record)) else {
            return set_alarm_at(&storage, purge_at).await;
        };
        run_pending_billing_attempt(&self.env, &storage, &billing_id, action, purge_at).await
    }
}

/// In-memory serialization of a non-storage-I/O window (the DO input gate
/// opens during such awaits). Drop releases the window on every exit path.
struct ActiveWindow<'a>(&'a Cell<bool>);

impl<'a> ActiveWindow<'a> {
    fn acquire(flag: &'a Cell<bool>) -> Option<Self> {
        if flag.get() {
            return None;
        }
        flag.set(true);
        Some(Self(flag))
    }
}

impl Drop for ActiveWindow<'_> {
    fn drop(&mut self) {
        self.0.set(false);
    }
}

fn pending_billing(record: Option<&JobRecord>) -> Option<(String, PendingBillingAction)> {
    let billing = record?.billing()?;
    Some((billing.billing_id.clone(), billing.pending?))
}

enum RunOutcome {
    Completed { result_json: String },
    FailedUpstream { status: u16, code: String },
}

async fn run_job(
    state: Rc<State>,
    env: Env,
    job_id: String,
    started_at: i64,
    request: crate::types::TranscriptAnalysisRequest,
) -> Result<()> {
    let outcome = match env.secret(GEMINI_API_KEY) {
        Ok(secret) => {
            let gemini_api_key = secret.to_string();
            let model_value = env
                .var(GEMINI_MODEL_ENV_VAR)
                .ok()
                .map(|value| value.to_string());
            let model = resolve_gemini_model(model_value.as_deref());
            match run_analysis(&gemini_api_key, model, request).await {
                Ok(response) => {
                    let result_json = serde_json::to_string(&response)?;
                    // A result over the named budget would only fail later at
                    // the DO storage write (128 KiB per-value platform
                    // limit), stranding the job as Running until the 600 s
                    // deadline with the model spend discarded (template
                    // storage budget). Chapter/claim counts are capped, so over-budget
                    // means degenerate model output (e.g. multi-kilobyte
                    // soft-violation titles): fail with a stable code
                    // instead. Content-free log: size only.
                    if result_json.len() > crate::types::MAX_RESULT_JSON_BYTES {
                        console_error!(
                            "Transcript-analysis result over budget: {} bytes",
                            result_json.len()
                        );
                        RunOutcome::FailedUpstream {
                            status: 502,
                            code: "result_oversized".to_string(),
                        }
                    } else {
                        RunOutcome::Completed { result_json }
                    }
                }
                Err(error) => RunOutcome::FailedUpstream {
                    status: error.status,
                    code: error.body.error,
                },
            }
        }
        Err(_) => RunOutcome::FailedUpstream {
            status: 503,
            code: "worker_secret_missing".to_string(),
        },
    };

    // The guard re-read also supplies the authoritative subject set: a
    // content-proven subject may have joined while the model ran, and the
    // terminal record must keep authorizing it.
    let current = read_record(&state.storage()).await?;
    let Some(JobRecord::Running {
        job_id: current_job_id,
        started_at: current_started_at,
        subjects,
        content_hash,
        billing,
    }) = current
    else {
        return Ok(());
    };
    if current_job_id != job_id || current_started_at != started_at {
        return Ok(());
    }

    let purge_at = now_seconds().saturating_add(JOB_RESULT_TTL_SECONDS);
    let record = match outcome {
        RunOutcome::Completed { result_json } => JobRecord::Completed {
            job_id,
            result_json,
            purge_at,
            subjects,
            content_hash,
            billing,
        },
        RunOutcome::FailedUpstream { status, code } => JobRecord::FailedUpstream {
            job_id,
            status,
            code,
            purge_at,
            subjects,
            content_hash,
            billing,
        },
    };
    apply_terminal_billing(&env, &state.storage(), record, purge_at).await
}

/// Turn a still-Running record whose run task errored into a terminal
/// failure (same guard as run_job's own terminal write: only the exact run
/// that started it may finish it).
async fn terminalize_failed_run(
    state: &Rc<State>,
    env: &Env,
    job_id: &str,
    started_at: i64,
) -> Result<()> {
    let current = read_record(&state.storage()).await?;
    let Some(JobRecord::Running {
        job_id: current_job_id,
        started_at: current_started_at,
        subjects,
        content_hash,
        billing,
    }) = current
    else {
        return Ok(());
    };
    if current_job_id != job_id || current_started_at != started_at {
        return Ok(());
    }
    let purge_at = now_seconds().saturating_add(JOB_RESULT_TTL_SECONDS);
    let record = JobRecord::FailedUpstream {
        job_id: job_id.to_string(),
        status: 500,
        code: "job_task_failed".to_string(),
        purge_at,
        subjects,
        content_hash,
        billing,
    };
    apply_terminal_billing(env, &state.storage(), record, purge_at).await
}

/// Shared terminal-billing transition (deliver-then-bill):
/// the terminal record is written FIRST — delivering or failing the result
/// never blocks on billing success — and it carries `pending` from the
/// moment it exists: an isolate death during the settle/release subrequest
/// must leave a marker the alarm machinery retries, never a clean-looking
/// record. The first attempt then runs through the shared attempt path
/// (retry alarm on failure, purge alarm on success).
async fn apply_terminal_billing(
    env: &Env,
    storage: &Storage,
    mut record: JobRecord,
    purge_at: i64,
) -> Result<()> {
    let Some(action) = terminal_billing_action(&record) else {
        write_record(storage, &record).await?;
        return set_alarm_at(storage, purge_at).await;
    };
    if let Some(billing) = record.billing_mut() {
        billing.pending = Some(action);
    }
    write_record(storage, &record).await?;
    let billing_id = record
        .billing()
        .expect("action implies billing")
        .billing_id
        .clone();
    run_pending_billing_attempt(env, storage, &billing_id, action, purge_at).await
}

/// One settle/release attempt plus its bookkeeping. The attempt's await
/// opens the DO input gate, so every write afterwards re-reads storage and
/// applies only to the exact record the attempt was made for — an
/// interleaved same-fingerprint resubmit's fresh record (and reservation)
/// must never be clobbered by state captured before the await.
async fn run_pending_billing_attempt(
    env: &Env,
    storage: &Storage,
    billing_id: &str,
    action: PendingBillingAction,
    fallback_purge_at: i64,
) -> Result<()> {
    if !attempt_billing_action(env, billing_id, action).await {
        return record_failed_billing_attempt(env, storage, billing_id, fallback_purge_at).await;
    }
    let Some(mut current) = reread_matching_terminal(storage, billing_id).await? else {
        return Ok(());
    };
    if let Some(billing) = current.billing_mut() {
        billing.pending = None;
    }
    let purge_at = current.purge_at().unwrap_or(fallback_purge_at);
    write_record(storage, &current).await?;
    set_alarm_at(storage, purge_at).await
}

/// Failed-attempt bookkeeping shared by the terminal path and the alarm
/// retries: bump attempts and pace the next retry, or abandon loudly at the
/// budget — and an abandoned settle still tries to free its hold.
async fn record_failed_billing_attempt(
    env: &Env,
    storage: &Storage,
    billing_id: &str,
    fallback_purge_at: i64,
) -> Result<()> {
    let Some(mut record) = reread_matching_terminal(storage, billing_id).await? else {
        // A fresh run owns the record now and manages its own billing;
        // nothing is left to retry the old action. Loud, and rare by
        // construction: billed restarts refuse to replace a pending record.
        console_error!(
            "transcript-analysis billing attempt failed for a replaced record; abandoned: {billing_id}"
        );
        return Ok(());
    };
    let purge_at = record.purge_at().unwrap_or(fallback_purge_at);
    let Some(action) = record.billing().and_then(|billing| billing.pending) else {
        return set_alarm_at(storage, purge_at).await;
    };
    let attempts = {
        let billing = record.billing_mut().expect("pending implies billing");
        billing.attempts = billing.attempts.saturating_add(1);
        billing.attempts
    };
    if attempts < BILLING_MAX_ATTEMPTS {
        write_record(storage, &record).await?;
        return storage
            .set_alarm(Duration::from_secs(billing_retry_delay_seconds(
                purge_at,
                now_seconds(),
            )))
            .await;
    }
    if let Some(billing) = record.billing_mut() {
        billing.pending = None;
    }
    write_record(storage, &record).await?;
    set_alarm_at(storage, purge_at).await?;
    console_error!(
        "transcript-analysis billing {action:?} abandoned after {attempts} attempts: {billing_id}"
    );
    release_abandoned_settle(env, billing_id, action).await;
    Ok(())
}

/// Last resort for an abandoned settle: free the hold instead of stranding
/// it. Safe on both backends — release after a settle that actually landed
/// is a no-op that keeps the charge.
async fn release_abandoned_settle(env: &Env, billing_id: &str, abandoned: PendingBillingAction) {
    if abandoned != PendingBillingAction::Settle {
        return;
    }
    if attempt_billing_action(env, billing_id, PendingBillingAction::Release).await {
        worker::console_log!(
            "transcript-analysis abandoned settle released its hold: {billing_id}"
        );
    } else {
        console_error!(
            "transcript-analysis abandoned settle could not release its hold: {billing_id}"
        );
    }
}

/// Re-read after a gate-opening billing await: the stored record, but only
/// if it is still the terminal record the attempt was made for (same
/// billing id). `None` means an interleaved submit replaced or purged it.
async fn reread_matching_terminal(
    storage: &Storage,
    billing_id: &str,
) -> Result<Option<JobRecord>> {
    let Some(current) = read_record(storage).await? else {
        return Ok(None);
    };
    if current.purge_at().is_none()
        || current.billing().map(|billing| billing.billing_id.as_str()) != Some(billing_id)
    {
        return Ok(None);
    }
    Ok(Some(current))
}

/// One reserve attempt against the configured backend. `Err` = config or
/// authority failure (the caller fails closed); `Ok(Err(response))` = typed
/// refusal to forward.
async fn reserve_billing(
    env: &Env,
    context: &BillingContext,
) -> Result<std::result::Result<JobBillingState, Response>> {
    let config = AppConfig::from_env(env)
        .map_err(|error| worker::Error::RustError(format!("{error:?}")))?;
    let credit = config.credit_authority(env)?;
    let billing_id = mint_billing_id()?;
    match credit
        .reserve(
            &context.account_id,
            &billing_id,
            context.charge_seconds,
            now_seconds(),
        )
        .await
    {
        Ok(_) => Ok(Ok(JobBillingState::reserved(
            billing_id,
            context.charge_seconds,
        ))),
        Err(error) => {
            if matches!(error, CreditError::Internal(_)) {
                // An Internal failure may have LANDED upstream (lost
                // response, decode failure, PurchaseWorker admitting the
                // hold before its index write threw). Best-effort release:
                // a no-op for a hold that never existed, a repair for one
                // that did — otherwise the client's retry double-holds.
                credit.release(&billing_id, now_seconds()).await.ok();
            }
            Ok(Err(reserve_failure_response(&credit, context, error).await?))
        }
    }
}

/// One settle/release attempt against the configured credit backend. Config
/// or authority construction failures count as attempt failures — never a
/// silent skip after repeated failures — and every failure logs its
/// cause: these arms are exactly where flip-day misconfiguration surfaces.
async fn attempt_billing_action(
    env: &Env,
    billing_id: &str,
    action: PendingBillingAction,
) -> bool {
    let config = match AppConfig::from_env(env) {
        Ok(config) => config,
        Err(error) => {
            console_error!("transcript-analysis billing config invalid: {error:?}");
            return false;
        }
    };
    let credit = match config.credit_authority(env) {
        Ok(credit) => credit,
        Err(error) => {
            console_error!("transcript-analysis credit authority unavailable: {error}");
            return false;
        }
    };
    let result = match action {
        PendingBillingAction::Settle => credit.settle(billing_id, now_seconds()).await,
        PendingBillingAction::Release => credit.release(billing_id, now_seconds()).await,
    };
    if let Err(error) = &result {
        console_error!(
            "transcript-analysis billing {action:?} failed for {billing_id}: {}",
            error.code()
        );
    }
    result.is_ok()
}

async fn read_record(storage: &Storage) -> Result<Option<JobRecord>> {
    let Some(raw) = storage.get::<String>(JOB_STORAGE_KEY).await? else {
        return Ok(None);
    };
    Ok(Some(serde_json::from_str(&raw)?))
}

async fn write_record(storage: &Storage, record: &JobRecord) -> Result<()> {
    storage
        .put(JOB_STORAGE_KEY, serde_json::to_string(record)?)
        .await
}

async fn set_alarm_at(storage: &Storage, target_seconds: i64) -> Result<()> {
    let delay = target_seconds.saturating_sub(now_seconds()).max(0) as u64;
    storage.set_alarm(Duration::from_secs(delay)).await
}

fn job_status(status: u16, job_id: &str, state: &str, poll_after: u64) -> Result<Response> {
    json_body(
        status,
        &serde_json::json!({
            "job_id": job_id,
            "state": state,
            "poll_after_seconds": poll_after,
        }),
    )
}

fn json_error(status: u16, code: &'static str) -> Result<Response> {
    json_body(status, &ErrorResponse::new(code))
}

fn json_error_owned(status: u16, code: String) -> Result<Response> {
    json_body(status, &ErrorResponse::new(code))
}

fn json_body(status: u16, body: &impl serde::Serialize) -> Result<Response> {
    raw_json(status, serde_json::to_string(body)?)
}

fn raw_json(status: u16, body: String) -> Result<Response> {
    let headers = Headers::new();
    headers.set("content-type", JSON_CONTENT_TYPE)?;
    Ok(Response::builder()
        .with_status(status)
        .with_headers(headers)
        .fixed(body.into_bytes()))
}

fn now_seconds() -> i64 {
    (Date::now().as_millis() / 1_000)
        .try_into()
        .unwrap_or(i64::MAX)
}

fn day_index() -> u64 {
    Date::now().as_millis() / 86_400_000
}
