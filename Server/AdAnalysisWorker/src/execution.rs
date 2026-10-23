use futures_util::future::{select, Either};
use std::{cell::Cell, rc::Rc, time::Duration};
use worker::{Date, Delay, Env, Headers, Method, Request, RequestInit, Stub};

use crate::{
    accounting::{self, ExchangeFailure, Operation, Summary},
    analysis::UpstreamError,
    types::{ErrorResponse, GeminiUsage},
    usage::{global_usage_object_name, UsageLimitProfile, USAGE_LIMITER_BINDING},
    validation::DailyUsage,
};

/// Shared only within one admitted run. Durable attempt state remains in the
/// daily limiter; dropping a window cannot refund a dispatched unknown call.
pub(crate) struct Execution {
    env: Env,
    request: accounting::Request,
    pub deadline_ms: u64,
    cancelled: Cell<bool>,
    revision: &'static str,
    call_timeout_seconds: u64,
}

impl Execution {
    pub async fn admit(
        env: &Env,
        caller_object: &str,
        profile: UsageLimitProfile,
        policy: crate::policy::AnalysisPolicy,
        execution_tokens: u64,
        segment_count: usize,
    ) -> Result<Rc<Self>, UpstreamError> {
        let now = now_ms();
        let run_id = opencast_app_attest_core::random::random_urlsafe_token(24)
            .map_err(|_| unavailable())?;
        let revision = if policy == crate::policy::AnalysisPolicy::V3 {
            crate::policy::V3_REVISION
        } else {
            crate::types::POLICY_NAME
        };
        let legacy_caller: DailyUsage = post(
            env,
            caller_object,
            "/snapshot",
            &serde_json::json!({}),
            Trace {
                op: "snapshot",
                run_id: &run_id,
                revision,
            },
        )
        .await?;
        let execution = Rc::new(Self {
            env: env.clone(),
            call_timeout_seconds: policy.call_timeout_seconds(segment_count),
            deadline_ms: now + crate::policy::V3_EXECUTION_SECONDS * 1000,
            cancelled: Cell::new(false),
            revision,
            request: accounting::Request {
                run_id,
                subject: caller_object.into(),
                profile,
                day: now / 86_400_000,
                legacy_caller,
                operation: Operation::Admit {
                    execution_tokens,
                    expires_at: now / 1000 + 600,
                },
            },
        });
        execution
            .update(execution.request.operation.clone())
            .await?;
        Ok(execution)
    }

    pub fn run_id(&self) -> &str {
        &self.request.run_id
    }

    pub fn cancel(&self) {
        self.cancelled.set(true);
    }

    pub fn check(&self) -> Result<(), UpstreamError> {
        if self.cancelled.get() || now_ms() >= self.deadline_ms {
            return Err(failure("analysis_deadline_exhausted"));
        }
        Ok(())
    }

    pub fn call_timeout(&self) -> Result<Duration, UpstreamError> {
        self.check()?;
        let remaining = self.deadline_ms.saturating_sub(now_ms());
        if remaining < 1000 {
            return Err(failure("analysis_deadline_exhausted"));
        }
        Ok(Duration::from_millis(
            remaining.min(self.call_timeout_seconds * 1000),
        ))
    }

    pub async fn backoff(&self, seconds: u64) -> Result<(), UpstreamError> {
        self.check()?;
        if seconds > crate::policy::V3_MAX_BACKOFF_SECONDS
            || now_ms().saturating_add((seconds + self.call_timeout_seconds) * 1000)
                > self.deadline_ms
        {
            return Err(failure("analysis_deadline_exhausted"));
        }
        Delay::from(Duration::from_secs(seconds)).await;
        self.check()
    }

    pub async fn dispatch(&self, attempt: u8, input_tokens: u64) -> Result<(), UpstreamError> {
        self.call_timeout()?;
        self.update(Operation::Reserve {
            attempt,
            input_tokens,
        })
        .await?;
        self.check()?;
        match self.update(Operation::Dispatch { attempt }).await {
            Ok(_) => Ok(()),
            Err(failed)
                if accounting::dispatch_replay_committed(
                    failed.attempt,
                    &failed.error.body.error,
                ) =>
            {
                Ok(())
            }
            Err(failed) => Err(failed.error),
        }
    }

    pub async fn receipt(
        &self,
        attempt: u8,
        usage: Option<GeminiUsage>,
    ) -> Result<(), UpstreamError> {
        if let Some(usage) = usage {
            self.update(Operation::Receipt { attempt, usage }).await?;
        }
        Ok(())
    }

    pub async fn finish(&self) -> Result<Summary, UpstreamError> {
        let summary = self.update(Operation::Finish).await?;
        worker::console_log!(
            "{}",
            serde_json::json!({"event":"ad_analysis_accounting", "policy_revision":self.revision, "run_id":self.run_id(), "accounting":summary})
        );
        Ok(summary)
    }

    async fn update(&self, operation: Operation) -> Result<Summary, Failed> {
        let trace = Trace {
            op: operation.name(),
            run_id: self.run_id(),
            revision: self.revision,
        };
        let mut request = self.request.clone();
        request.operation = operation;
        post(
            &self.env,
            &global_usage_object_name(request.day),
            "/account",
            &request,
            trace,
        )
        .await
    }
}

/// Names a limiter exchange in content-free failure telemetry.
#[derive(Clone, Copy)]
struct Trace<'a> {
    op: &'static str,
    run_id: &'a str,
    revision: &'static str,
}

/// A failed limiter exchange and the try that produced it.
struct Failed {
    error: UpstreamError,
    attempt: u8,
}

/// Failures before any exchange (binding, stub, encoding) belong to the first try.
impl From<UpstreamError> for Failed {
    fn from(error: UpstreamError) -> Self {
        Self { error, attempt: 0 }
    }
}

impl From<Failed> for UpstreamError {
    fn from(failed: Failed) -> Self {
        failed.error
    }
}

async fn post<T: serde::de::DeserializeOwned>(
    env: &Env,
    object: &str,
    path: &str,
    body: &impl serde::Serialize,
    trace: Trace<'_>,
) -> Result<T, Failed> {
    let namespace = env
        .durable_object(USAGE_LIMITER_BINDING)
        .map_err(|_| unavailable())?;
    let url = format!("https://usage-limiter.opencast.internal{path}");
    let body = serde_json::to_string(body).map_err(|_| unavailable())?;
    let mut attempt = 0;
    loop {
        // An infrastructure exception can leave a stub broken for good, so
        // every try gets a fresh one.
        let stub = namespace.get_by_name(object).map_err(|_| unavailable())?;
        let request = limiter_request(&url, &body).map_err(|_| unavailable())?;
        let started = now_ms();
        let (failure, error) = match exchange(&stub, request).await {
            Ok(value) => return Ok(value),
            Err(failed) => failed,
        };
        worker::console_log!(
            "{}",
            serde_json::json!({
                "event": "ad_analysis_accounting_error",
                "op": trace.op,
                "kind": failure.kind(),
                "status": failure.status(),
                "code": matches!(failure, ExchangeFailure::Status { .. }).then_some(&error.body.error),
                "attempt": attempt,
                "elapsed_ms": now_ms().saturating_sub(started),
                "run_id": trace.run_id,
                "policy_revision": trace.revision,
            })
        );
        if !failure.retryable() || attempt + 1 >= accounting::EXCHANGE_ATTEMPTS {
            return Err(Failed { error, attempt });
        }
        attempt += 1;
        Delay::from(Duration::from_millis(250)).await;
    }
}

fn limiter_request(url: &str, body: &str) -> worker::Result<Request> {
    let headers = Headers::new();
    headers.set("content-type", "application/json")?;
    let mut init = RequestInit::new();
    init.with_method(Method::Post)
        .with_headers(headers)
        .with_body(Some(body.into()));
    Request::new_with_init(url, &init)
}

/// One five-second exchange; a dropped timeout leaves no limiter decision.
async fn exchange<T: serde::de::DeserializeOwned>(
    stub: &Stub,
    request: Request,
) -> Result<T, (ExchangeFailure, UpstreamError)> {
    let exchange = std::pin::pin!(async {
        let mut response = stub
            .fetch_with_request(request)
            .await
            .map_err(|_| (ExchangeFailure::Transport, unavailable()))?;
        let status = response.status_code();
        if status != 200 {
            return Err(match response.json().await {
                Ok(body) => (
                    ExchangeFailure::Status { status },
                    UpstreamError { status, body },
                ),
                Err(_) => (
                    ExchangeFailure::Decode { status },
                    UpstreamError {
                        status,
                        body: ErrorResponse::new("usage_limiter_error"),
                    },
                ),
            });
        }
        response
            .json()
            .await
            .map_err(|_| (ExchangeFailure::Decode { status }, unavailable()))
    });
    let timeout = std::pin::pin!(Delay::from(Duration::from_secs(5)));
    match select(exchange, timeout).await {
        Either::Left((result, _)) => result,
        Either::Right(_) => Err((ExchangeFailure::Timeout, unavailable())),
    }
}

pub(crate) fn now_ms() -> u64 {
    Date::now().as_millis()
}
pub(crate) async fn complete(
    mut outcome: Result<crate::types::AdAnalysisResponse, UpstreamError>,
    execution: &Execution,
    policy: crate::policy::AnalysisPolicy,
) -> Result<crate::types::AdAnalysisResponse, UpstreamError> {
    if policy == crate::policy::AnalysisPolicy::V2 {
        if let Ok(response) = &outcome {
            execution.receipt(0, response.usage.clone()).await?;
        }
    }
    // If the finish receipt is lost, expiry releases only unstarted holds.
    let accounting = execution.finish().await.ok();
    match &mut outcome {
        Ok(response) => response.accounting = accounting,
        Err(error) => {
            error.body.accounting = accounting.map(Box::new);
            if let Some(failure) = &mut error.body.failure {
                failure.policy_revision = Some(
                    if policy == crate::policy::AnalysisPolicy::V3 {
                        crate::policy::V3_REVISION
                    } else {
                        crate::types::POLICY_NAME
                    }
                    .into(),
                );
            }
        }
    }
    outcome
}
fn unavailable() -> UpstreamError {
    failure("usage_limiter_error")
}
pub(crate) fn failure(code: &str) -> UpstreamError {
    UpstreamError {
        status: 503,
        body: ErrorResponse::new(code),
    }
}
