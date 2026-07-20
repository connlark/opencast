use std::cell::Cell;
use std::rc::Rc;
use std::time::Duration;

use worker::{
    console_error, durable_object, wasm_bindgen, Date, Delay, DurableObject, Env, Headers, Method,
    Request, Response, Result, State, Storage,
};

use crate::analysis::run_windows_analysis;
use crate::job::{
    alarm_decision, poll_decision, submit_decision, AlarmDecision, JobRecord, JobSubmitRequest,
    PollDecision, SubmitDecision, JOB_HEARTBEAT_SECONDS, JOB_POLL_AFTER_SECONDS,
    JOB_RESULT_TTL_SECONDS, JOB_SUBMIT_POLL_AFTER_SECONDS,
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
            INTERNAL_POLL_PATH => self.handle_poll().await,
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

        loop {
            let record = read_record(&self.state.storage()).await?;
            match submit_decision(record.as_ref()) {
                SubmitDecision::Attach { job_id } => {
                    return job_status(202, &job_id, "running", JOB_SUBMIT_POLL_AFTER_SECONDS);
                }
                SubmitDecision::ServeCompleted { result_json, .. } => {
                    self.purge().await?;
                    return raw_json(200, result_json);
                }
                SubmitDecision::Start => {}
            }

            // Non-storage I/O opens the DO input gate. Serialize the admission
            // window in memory so concurrent identical submits cannot both
            // consume quota before the Running record is persisted.
            if self.admission_active.get() {
                Delay::from(Duration::from_millis(10)).await;
                continue;
            }
            self.admission_active.set(true);
            let admission = admit_spend_caps(
                &self.env,
                &submit.usage_object_name,
                submit.usage_profile,
                day_index(),
                submit.estimated_input_tokens,
            )
            .await;
            self.admission_active.set(false);
            if let Some(response) = admission? {
                return Ok(response);
            }

            let job_id = submit.request.transcript.fingerprint.clone();
            let started_at = now_seconds();
            let running = JobRecord::Running {
                job_id: job_id.clone(),
                started_at,
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
            worker::wasm_bindgen_futures::spawn_local(async move {
                if let Err(error) = run_job(state, env, job_id, started_at, request).await {
                    console_error!("Ad-analysis job task failed: {error:?}");
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

    async fn handle_poll(&self) -> Result<Response> {
        let record = read_record(&self.state.storage()).await?;
        match poll_decision(record.as_ref()) {
            PollDecision::NotFound => json_error(404, "job_not_found"),
            PollDecision::Running { job_id } => {
                job_status(202, &job_id, "running", JOB_POLL_AFTER_SECONDS)
            }
            PollDecision::ServeCompleted { result_json, .. } => {
                self.purge().await?;
                raw_json(200, result_json)
            }
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

async fn run_job(
    state: Rc<State>,
    env: Env,
    job_id: String,
    started_at: i64,
    request: crate::types::AdAnalysisRequest,
) -> Result<()> {
    let record = match env.secret(GEMINI_API_KEY) {
        Ok(secret) => {
            let gemini_api_key = secret.to_string();
            let model_value = env
                .var(GEMINI_MODEL_ENV_VAR)
                .ok()
                .map(|value| value.to_string());
            let model = resolve_gemini_model(model_value.as_deref());
            match run_windows_analysis(&gemini_api_key, model, request).await {
                Ok(response) => JobRecord::Completed {
                    job_id: job_id.clone(),
                    result_json: serde_json::to_string(&response)?,
                    purge_at: now_seconds().saturating_add(JOB_RESULT_TTL_SECONDS),
                },
                Err(error) => JobRecord::FailedUpstream {
                    job_id: job_id.clone(),
                    status: error.status,
                    code: error.body.error,
                    purge_at: now_seconds().saturating_add(JOB_RESULT_TTL_SECONDS),
                },
            }
        }
        Err(_) => JobRecord::FailedUpstream {
            job_id: job_id.clone(),
            status: 503,
            code: "worker_secret_missing".to_string(),
            purge_at: now_seconds().saturating_add(JOB_RESULT_TTL_SECONDS),
        },
    };

    let current = read_record(&state.storage()).await?;
    if !matches!(
        current,
        Some(JobRecord::Running {
            job_id: ref current_job_id,
            started_at: current_started_at,
        }) if current_job_id == &job_id && current_started_at == started_at
    ) {
        return Ok(());
    }
    let purge_at = match &record {
        JobRecord::Completed { purge_at, .. } | JobRecord::FailedUpstream { purge_at, .. } => {
            *purge_at
        }
        JobRecord::Running { .. } | JobRecord::FailedTransient { .. } => {
            unreachable!("run task only creates completed or upstream-failed records")
        }
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
