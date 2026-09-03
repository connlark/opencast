use std::cell::Cell;
use std::rc::Rc;
use std::time::Duration;

use worker::{
    console_error, durable_object, wasm_bindgen, Date, Delay, DurableObject, Env, Headers, Method,
    Request, Response, Result, State, Storage,
};

use crate::analysis::run_windows_analysis;
use crate::job::{
    alarm_decision, poll_decision, submit_decision, transcript_content_hash, ActiveWindow,
    AlarmDecision, JobDoPollRequest, JobRecord, JobSubmitRequest, PollDecision, SubmitDecision,
    ERROR_ADMISSION_BUSY, JOB_HEARTBEAT_SECONDS, JOB_POLL_AFTER_SECONDS, JOB_RESULT_TTL_SECONDS,
    JOB_SUBMIT_POLL_AFTER_SECONDS, SUBMIT_ADMISSION_MAX_WAITS, SUBMIT_ADMISSION_WAIT_MILLIS,
};
use crate::route::JSON_CONTENT_TYPE;
use crate::types::{resolve_gemini_model, ErrorResponse, GEMINI_MODEL_ENV_VAR};
use crate::worker_app::admit_spend_caps;

const JOB_STORAGE_KEY: &str = "job";
const GEMINI_API_KEY: &str = "GEMINI_API_KEY";
const INTERNAL_SUBMIT_PATH: &str = "/submit";
const INTERNAL_POLL_PATH: &str = "/poll";

#[durable_object(alarm)]
pub struct AdAnalysisJob {
    state: Rc<State>,
    env: Env,
    run_active: Cell<bool>,
    admission_active: Cell<bool>,
}

impl DurableObject for AdAnalysisJob {
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
            AlarmDecision::Purge => self.purge().await?,
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
                write_record(&self.state.storage(), &record).await?;
                set_alarm_at(&self.state.storage(), *purge_at).await?;
            }
        }
        Response::ok("")
    }
}

impl AdAnalysisJob {
    async fn handle_submit(&self, req: &mut Request) -> Result<Response> {
        let submit = match req.json::<JobSubmitRequest>().await {
            Ok(submit) => submit,
            Err(_) => return json_error(400, "malformed_json"),
        };
        let submitted_hash =
            transcript_content_hash(&submit.request.transcript, &submit.request.segments);

        let mut admission_waits: u32 = 0;
        loop {
            let mut record = read_record(&self.state.storage()).await?;
            match submit_decision(
                record.as_ref(),
                &submit.subject,
                &submitted_hash,
                submit.internal,
            ) {
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
                // Replace: a trusted internal submit over a squatted name
                // starts fresh below exactly like Start — the new Running
                // record (new started_at) drops the squatter's subjects, and
                // the stale-run guard discards the squatted task's result.
                SubmitDecision::Start | SubmitDecision::Replace => {}
            }

            // Non-storage I/O opens the DO input gate. Serialize the admission
            // window in memory so concurrent identical submits cannot both
            // consume quota before the Running record is persisted. The
            // window's Drop releases it on every exit path (error
            // propagation and a dropped request future included), and the
            // wait is bounded so a wedged window degrades to a 503.
            let Some(_admission_window) = ActiveWindow::acquire(&self.admission_active) else {
                if admission_waits >= SUBMIT_ADMISSION_MAX_WAITS {
                    return json_error(503, ERROR_ADMISSION_BUSY);
                }
                admission_waits += 1;
                Delay::from(Duration::from_millis(SUBMIT_ADMISSION_WAIT_MILLIS)).await;
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
            };
            write_record(&self.state.storage(), &running).await?;
            self.state
                .storage()
                .set_alarm(Duration::from_secs(JOB_HEARTBEAT_SECONDS))
                .await?;
            self.run_active.set(true);

            let state = self.state.clone();
            let env = self.env.clone();
            let request = submit.request;
            let response_job_id = job_id.clone();
            let recovery_state = self.state.clone();
            let recovery_job_id = job_id.clone();
            worker::wasm_bindgen_futures::spawn_local(async move {
                if let Err(error) = run_job(state, env, job_id, started_at, request).await {
                    console_error!("Ad-analysis job task failed: {error:?}");
                    // AA-5: a paid model call whose bookkeeping failed (for
                    // example the terminal record write) must not leave the
                    // record Running until the 600 s deadline. Best-effort:
                    // the failure record is small, so this write succeeds
                    // even when the completed record's did not.
                    if let Err(recovery_error) =
                        terminalize_failed_run(&recovery_state, &recovery_job_id, started_at).await
                    {
                        console_error!(
                            "Ad-analysis failed-run terminalization failed: {recovery_error:?}"
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
            // resubmit — or the internal alarm loop's 404 path — start a
            // fresh run instead of re-reading a dead record.
            PollDecision::ServeCompleted { result_json, .. } => raw_json(200, result_json),
            PollDecision::ServeFailedUpstream { status, code } => {
                self.purge().await?;
                json_error_owned(status, code)
            }
            PollDecision::ServeFailedTransient => {
                self.purge().await?;
                json_error(503, "job_failed_transient")
            }
        }
    }

    async fn purge(&self) -> Result<()> {
        self.state.storage().delete_all().await?;
        self.state.storage().delete_alarm().await
    }
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
    request: crate::types::AdAnalysisRequest,
) -> Result<()> {
    let outcome = match env.secret(GEMINI_API_KEY) {
        Ok(secret) => {
            let gemini_api_key = secret.to_string();
            let model_value = env
                .var(GEMINI_MODEL_ENV_VAR)
                .ok()
                .map(|value| value.to_string());
            let model = resolve_gemini_model(model_value.as_deref());
            match run_windows_analysis(&gemini_api_key, model, request).await {
                Ok(response) => {
                    let result_json = serde_json::to_string(&response)?;
                    // AA-5: a result over the named budget would only fail
                    // later at the DO storage write (128 KiB per-value
                    // platform limit), stranding the job as Running until
                    // the 600 s deadline with the model spend discarded.
                    // Validated spans and the echoed request_id are capped,
                    // so over-budget means degenerate model output: fail
                    // with a stable code instead. Content-free log: size
                    // only.
                    if result_json.len() > crate::types::MAX_RESULT_JSON_BYTES {
                        console_error!(
                            "Ad-analysis result over budget: {} bytes",
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
        },
        RunOutcome::FailedUpstream { status, code } => JobRecord::FailedUpstream {
            job_id,
            status,
            code,
            purge_at,
            subjects,
            content_hash,
        },
    };
    write_record(&state.storage(), &record).await?;
    set_alarm_at(&state.storage(), purge_at).await
}

/// AA-5 leg 3: turn a still-Running record whose run task errored into a
/// terminal failure (same guard as run_job's own terminal write: only the
/// exact run that started it may finish it).
async fn terminalize_failed_run(state: &Rc<State>, job_id: &str, started_at: i64) -> Result<()> {
    let current = read_record(&state.storage()).await?;
    let Some(JobRecord::Running {
        job_id: current_job_id,
        started_at: current_started_at,
        subjects,
        content_hash,
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
    };
    write_record(&state.storage(), &record).await?;
    set_alarm_at(&state.storage(), purge_at).await
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
