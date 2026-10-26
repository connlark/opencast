//! The request path: route, authenticate (App Attest envelope or the ops
//! bearer), validate and rebuild the Gemini body, count its tokens, admit at
//! the ledger, forward with opencast's key, settle, and answer with the
//! provider's reply. Nothing from a request or a reply is logged: every log
//! line is a `telemetry` struct, and no error's `Display` is ever written.

use std::cell::Cell;
use std::future::Future;

use futures_util::future::{select, Either};
use futures_util::StreamExt;
use opencast_app_attest_core::app_attest::{challenge_hash, verify_attestation};
use opencast_app_attest_core::app_attest_envelope::slice_c::{
    authenticate_envelope_with_storage, AttestStorage, D1AttestStorage,
};
use opencast_app_attest_core::app_attest_storage as storage;
use opencast_app_attest_core::auth::{bearer_token, token_matches, AUTHORIZATION_HEADER};
use opencast_app_attest_core::challenge_limits::{
    challenge_bucket_start, keyed_source_token, source_challenge_allows_after_increment,
    APP_ATTEST_KEY_LIMIT_WINDOW_SECONDS, CHALLENGE_LIMIT_WINDOW_SECONDS,
    CHALLENGE_RETENTION_SECONDS, CHALLENGE_SOURCE_BUCKET_RETENTION_SECONDS, CHALLENGE_TTL_SECONDS,
    MAX_APP_ATTEST_KEYS_PER_INSTALL_PER_DAY,
};
use opencast_app_attest_core::random::random_urlsafe_token;
use serde::Deserialize;
use worker::js_sys::Uint8Array;
use worker::{
    console_log, AbortController, Date, Delay, Env, Fetch, Headers, Method, Request, RequestInit,
    RequestRedirect, Response, ResponseBody, Result, Stub,
};

use crate::admission::{
    admit_deadline_ms, admit_request, app_attest_subject, bearer_subject, exchange_timeout_ms,
    forward_budget_ms, plan, status_window, SETTLE_FLOOR_MS,
};
use crate::bundle::{self, TrialBundle};
use crate::config::{self, ConfigError, ConfigField, ConfigReason, TrialConfig, VarSource};
use crate::identifiers::{self, CHALLENGE_BYTES, CHALLENGE_ID_BYTES};
use crate::ledger::{Decision, Lane, RefusalCode, SettleResult, StatusView};
use crate::ledger_do::{AdmitResponse, SettleRequest, StatusRequest};
use crate::provider::{
    classify_reply, count_tokens_body, parse_count_tokens, sanitized_retry_after, status_family,
    AmbiguousClass, SettleOutcome, COUNT_FAILED_RETRY_AFTER_SECONDS, MAX_PROVIDER_BODY_BYTES,
};
use crate::request::{parse_window, RequestError, TrialWindow};
use crate::route::{
    error_body, refused_unlogged, route, ChallengeSourceFailure, ProxyCode, RouteAction,
    StatusBody, JSON_CONTENT_TYPE, TRIAL_ANALYZE_PATH, TRIAL_STATUS_PATH,
};
use crate::telemetry::{line, ConfigErrorEvent, ForwardEvent, StageEvent, StatusEvent};

pub const TRIAL_DB: &str = "TRIAL_DB";
pub const LEDGER_BINDING: &str = "TRIAL_LEDGER";
pub const LEDGER_OBJECT_NAME: &str = "global";
const LEDGER_URL: &str = "https://trial-ledger.opencast.internal";
const GEMINI_API_KEY: &str = "GEMINI_API_KEY";
const TRIAL_BEARER_TOKEN: &str = "TRIAL_BEARER_TOKEN";
const CHALLENGE_SOURCE_HASH_KEY: &str = "CHALLENGE_SOURCE_HASH_KEY";
const DEVELOPMENT_CHALLENGE_SOURCE_HASH_KEY: &str =
    "opencast-trial-development-challenge-source-key";
const REGISTER_PURPOSE: &str = "register";
const MAX_CHALLENGE_REQUEST_BODY_BYTES: usize = 1024;
const MAX_REGISTER_REQUEST_BODY_BYTES: usize = 48 * 1024;
const MAX_STATUS_BODY_BYTES: usize = 16 * 1024;
const MAX_COUNT_REPLY_BYTES: usize = 64 * 1024;
const LEDGER_EXCHANGE_ATTEMPTS: u32 = 2;
/// A status readback is not part of a device's call budget.
const STATUS_EXCHANGE_BUDGET_MS: i64 = 10_000;
const MAX_CONTENT_TYPE_CHARS: usize = 128;

pub struct EnvVars<'a>(pub &'a Env);

impl VarSource for EnvVars<'_> {
    fn var(&self, name: &str) -> Option<String> {
        self.0.var(name).ok().map(|value| value.to_string())
    }
}

pub fn json_response(status: u16, body: Vec<u8>) -> Result<Response> {
    let headers = Headers::new();
    headers.set("content-type", JSON_CONTENT_TYPE)?;
    headers.set("cache-control", "no-store")?;
    Ok(Response::builder()
        .with_status(status)
        .with_headers(headers)
        .fixed(body))
}

fn proxy_response(code: ProxyCode, retry_after_seconds: Option<u64>) -> Response {
    let built = json_response(code.status(), error_body(code, retry_after_seconds)).and_then(
        |mut response| {
            if let Some(seconds) = retry_after_seconds {
                response
                    .headers_mut()
                    .set("retry-after", &seconds.to_string())?;
            }
            Ok(response)
        },
    );
    // Headers that cannot be set: the same code without them, never a panic.
    built.unwrap_or_else(|_| {
        Response::builder()
            .with_status(code.status())
            .fixed(error_body(code, retry_after_seconds))
    })
}

fn now_ms() -> i64 {
    i64::try_from(Date::now().as_millis()).unwrap_or(i64::MAX)
}

fn log_stage(stage: &'static str, kind: &'static str) {
    console_log!(
        "{}",
        line(&StageEvent {
            event: "trial_internal",
            stage,
            kind,
        })
    );
}

fn log_config_error(error: ConfigError) {
    console_log!(
        "{}",
        line(&ConfigErrorEvent {
            event: "trial_config_error",
            field: error.field.as_str(),
            reason: error.reason.as_str(),
        })
    );
}

/// The Worker's entry point. Never returns an error to the runtime (which
/// would log it with the request's URL): a `worker::Error` can carry text
/// from the request, so every failure becomes `trial_unavailable` and one
/// static log line here.
pub async fn handle_request(mut req: Request, env: Env) -> Response {
    let started = now_ms();
    // Before routing and before any log line. Unreadable counts as present.
    let has_query = req.url().map_or(true, |url| url.query().is_some());
    let has_key_header = req.headers().has("x-goog-api-key").unwrap_or(true);
    if refused_unlogged(has_key_header, has_query) {
        // Never forwarded, never counted, never logged.
        return proxy_response(ProxyCode::Refusal(RefusalCode::RequestInvalid), None);
    }
    match handle(&mut req, &env, started).await {
        Ok(response) => response,
        Err(_) => {
            log_stage("handler", "worker_error");
            proxy_response(ProxyCode::TrialUnavailable, None)
        }
    }
}

async fn handle(req: &mut Request, env: &Env, started: i64) -> Result<Response> {
    let action = route(req.method().as_ref(), &req.path());
    match action {
        RouteAction::Health => return health(),
        RouteAction::NotFound => return Ok(proxy_response(ProxyCode::NotFound, None)),
        RouteAction::MethodNotAllowed(allow) => {
            let mut response = proxy_response(ProxyCode::MethodNotAllowed, None);
            response.headers_mut().set("allow", allow)?;
            return Ok(response);
        }
        _ => {}
    }
    if !config::enabled(&EnvVars(env)) {
        return Ok(proxy_response(ProxyCode::TrialDisabled, None));
    }
    let bundle = match bundle::embedded() {
        Ok(bundle) => bundle,
        Err(error) => {
            log_config_error(ConfigError {
                field: ConfigField::Bundle,
                reason: ConfigReason::Bundle(error.reason()),
            });
            return Ok(proxy_response(ProxyCode::TrialUnavailable, None));
        }
    };
    let config = match config::load(&EnvVars(env), bundle) {
        Ok(config) => config,
        Err(error) => {
            log_config_error(error);
            return Ok(proxy_response(ProxyCode::TrialUnavailable, None));
        }
    };
    match action {
        RouteAction::Challenge => challenge(req, env).await,
        RouteAction::Register => register(req, env, &config).await,
        RouteAction::Analyze => Ok(analyze(req, env, &config, bundle, started).await),
        RouteAction::Status => Ok(status(req, env, &config, bundle, false).await),
        RouteAction::StatusBearer => Ok(status(req, env, &config, bundle, true).await),
        RouteAction::Health | RouteAction::NotFound | RouteAction::MethodNotAllowed(_) => {
            Ok(proxy_response(ProxyCode::NotFound, None))
        }
    }
}

fn health() -> Result<Response> {
    match bundle::embedded() {
        Ok(bundle) => json_response(
            200,
            serde_json::to_vec(&serde_json::json!({
                "message": "ok",
                "bundle_version": bundle.bundle_version,
                "trial_model": bundle.model,
            }))?,
        ),
        Err(_) => Ok(proxy_response(ProxyCode::TrialUnavailable, None)),
    }
}

/// Who is calling: the subject every counter keys on.
struct Caller {
    subject: String,
    lane: Lane,
}

/// Reads a body under a byte cap (`None` when over it).
async fn read_limited(req: &mut Request, max_bytes: usize) -> Result<Option<Vec<u8>>> {
    let declared = req
        .headers()
        .get("content-length")?
        .and_then(|value| value.trim().parse::<usize>().ok());
    if declared.is_some_and(|length| length > max_bytes) {
        return Ok(None);
    }
    // A request without a body (a GET) has no stream to read.
    if req.inner().body().is_none() {
        return Ok(Some(Vec::new()));
    }
    let mut stream = req.stream()?;
    let mut bytes = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        if bytes.len().saturating_add(chunk.len()) > max_bytes {
            return Ok(None);
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(Some(bytes))
}

/// The bearer lane when an `authorization` header is present (never a
/// fallback to the envelope), else the App Attest envelope bound to `path`.
async fn authenticate(
    req: &mut Request,
    env: &Env,
    config: &TrialConfig,
    path: &'static str,
    max_payload_bytes: usize,
    bearer_only: bool,
) -> Result<std::result::Result<(Caller, Vec<u8>), ProxyCode>> {
    let authorization = req.headers().get(AUTHORIZATION_HEADER)?;
    if let Some(authorization) = authorization {
        let Some(token) = bearer_token(Some(&authorization)) else {
            return Ok(Err(ProxyCode::Unauthorized));
        };
        let Ok(expected) = env.secret(TRIAL_BEARER_TOKEN) else {
            log_config_error(ConfigError {
                field: ConfigField::TrialBearerToken,
                reason: ConfigReason::Missing,
            });
            return Ok(Err(ProxyCode::TrialUnavailable));
        };
        if !token_matches(token, &expected.to_string()) {
            return Ok(Err(ProxyCode::Unauthorized));
        }
        let caller = Caller {
            subject: bearer_subject(token),
            lane: Lane::Bearer,
        };
        return Ok(match read_limited(req, max_payload_bytes).await? {
            Some(body) => Ok((caller, body)),
            None => Err(ProxyCode::PayloadTooLarge),
        });
    }
    if bearer_only {
        return Ok(Err(ProxyCode::Unauthorized));
    }
    // A POST without a body has no stream to open: malformed client input,
    // answered with AppAttestCore's own code for it.
    if req.inner().body().is_none() {
        return Ok(Err(ProxyCode::Auth {
            status: 400,
            code: "invalid_json",
        }));
    }
    let Ok(db) = env.d1(TRIAL_DB) else {
        return Ok(Err(ProxyCode::TrialUnavailable));
    };
    let checked = CheckedAttestStorage {
        inner: D1AttestStorage(&db),
        refused: Cell::new(false),
    };
    let authenticated = match authenticate_envelope_with_storage(
        req,
        &checked,
        &config.app_id,
        &config.app_attest_environment,
        now_ms() / 1_000,
        "POST",
        path,
        max_payload_bytes
            .saturating_mul(2)
            .saturating_add(16 * 1024),
        max_payload_bytes,
    )
    .await
    {
        Ok(Ok(authenticated)) => authenticated,
        Ok(Err(_)) if checked.refused.get() => {
            return Ok(Err(ProxyCode::Refusal(RefusalCode::RequestInvalid)))
        }
        Ok(Err(failure)) => {
            return Ok(Err(ProxyCode::Auth {
                status: failure.status,
                code: failure.code,
            }))
        }
        Err(_) => {
            log_stage("authenticate", "d1_error");
            return Ok(Err(ProxyCode::TrialUnavailable));
        }
    };
    Ok(Ok((
        Caller {
            subject: app_attest_subject(&authenticated.install_id),
            lane: Lane::AppAttest,
        },
        authenticated.payload.into_bytes(),
    )))
}

/// AppAttestCore's D1 key storage behind an install-id check: an envelope
/// whose install id is not the app's UUID never reaches D1. (The key id is
/// AppAttestCore's: canonical 32 bytes before any lookup.)
struct CheckedAttestStorage<'a> {
    inner: D1AttestStorage<'a>,
    refused: Cell<bool>,
}

impl AttestStorage for CheckedAttestStorage<'_> {
    fn read_key<'a>(
        &'a self,
        install: &'a str,
        key: &'a str,
    ) -> impl Future<Output = Result<Option<storage::AppAttestKeyRow>>> + 'a {
        let well_formed = identifiers::is_install_id(install);
        self.refused.set(!well_formed);
        async move {
            if !well_formed {
                return Ok(None);
            }
            self.inner.read_key(install, key).await
        }
    }

    fn compare_and_advance_counter<'a>(
        &'a self,
        install: &'a str,
        key: &'a str,
        previous: i64,
        next: i64,
        now: i64,
    ) -> impl Future<Output = Result<bool>> + 'a {
        self.inner
            .compare_and_advance_counter(install, key, previous, next, now)
    }
}

// ---------------------------------------------------------------------------
// Ledger exchanges.

#[derive(Clone, Copy)]
enum ExchangeError {
    Unavailable,
}

/// At most two exchanges, each bounded by what is left before `deadline_ms`
/// (and never below `floor_ms`): a slow ledger cannot push the exchange past
/// the device's budget. Admissions replay by reservation id and settlements
/// are idempotent, so a retry never doubles anything.
async fn ledger_exchange<T: for<'de> Deserialize<'de>>(
    env: &Env,
    path: &'static str,
    body: &impl serde::Serialize,
    deadline_ms: i64,
    floor_ms: i64,
) -> std::result::Result<T, ExchangeError> {
    let body = serde_json::to_string(body).map_err(|_| ExchangeError::Unavailable)?;
    let namespace = env
        .durable_object(LEDGER_BINDING)
        .map_err(|_| ExchangeError::Unavailable)?;
    for attempt in 0..LEDGER_EXCHANGE_ATTEMPTS {
        let floor = if attempt == 0 { floor_ms } else { 0 };
        let Some(timeout_ms) = exchange_timeout_ms(deadline_ms, now_ms(), floor) else {
            break;
        };
        // A broken stub can stay broken; every attempt gets a fresh one.
        let Ok(stub) = namespace.get_by_name(LEDGER_OBJECT_NAME) else {
            continue;
        };
        match exchange_once(&stub, path, &body, timeout_ms).await {
            Some(value) => return Ok(value),
            None => log_stage(path, if attempt == 0 { "retry" } else { "failed" }),
        }
    }
    Err(ExchangeError::Unavailable)
}

async fn exchange_once<T: for<'de> Deserialize<'de>>(
    stub: &Stub,
    path: &str,
    body: &str,
    timeout_ms: u64,
) -> Option<T> {
    let headers = Headers::new();
    headers.set("content-type", "application/json").ok()?;
    let mut init = RequestInit::new();
    init.with_method(Method::Post)
        .with_headers(headers)
        .with_body(Some(body.into()));
    let request = Request::new_with_init(&format!("{LEDGER_URL}{path}"), &init).ok()?;
    let exchange = std::pin::pin!(async {
        let mut response = stub.fetch_with_request(request).await.ok()?;
        if response.status_code() != 200 {
            return None;
        }
        response.json::<T>().await.ok()
    });
    let timeout = std::pin::pin!(Delay::from(std::time::Duration::from_millis(timeout_ms)));
    match select(exchange, timeout).await {
        Either::Left((value, _)) => value,
        Either::Right(_) => None,
    }
}

// ---------------------------------------------------------------------------
// Provider calls.

struct Reply {
    status: u16,
    body: Vec<u8>,
    content_type: Option<String>,
    retry_after: Option<u64>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum CallFailure {
    NotDispatched,
    /// No time was left to forward after admission.
    BudgetSpent,
    Timeout,
    Unreachable,
    TooLarge,
}

/// One POST to Google with opencast's key: exactly two headers, redirects
/// refused, one deadline over the fetch and the streamed body, a byte cap
/// enforced per chunk. No retry.
async fn provider_call(
    url: &str,
    key: &str,
    body: &[u8],
    timeout_ms: u64,
    max_bytes: usize,
) -> std::result::Result<Reply, CallFailure> {
    let controller = AbortController::default();
    let signal = controller.signal();
    let headers = Headers::new();
    let request = headers
        .set("content-type", "application/json")
        .and_then(|_| headers.set("x-goog-api-key", key))
        .and_then(|_| {
            let mut init = RequestInit::new();
            init.with_method(Method::Post)
                .with_headers(headers)
                .with_redirect(RequestRedirect::Manual)
                .with_body(Some(Uint8Array::from(body).into()));
            Request::new_with_init(url, &init)
        })
        .map_err(|_| CallFailure::NotDispatched)?;
    let exchange = std::pin::pin!(async {
        let mut response = Fetch::Request(request)
            .send_with_signal(&signal)
            .await
            .map_err(|_| CallFailure::Unreachable)?;
        let status = response.status_code();
        let retry_after = sanitized_retry_after(
            response
                .headers()
                .get("retry-after")
                .ok()
                .flatten()
                .as_deref(),
        );
        let content_type = response
            .headers()
            .get("content-type")
            .ok()
            .flatten()
            .filter(|value| value.len() <= MAX_CONTENT_TYPE_CHARS && value.is_ascii());
        let mut bytes = Vec::new();
        // A reply without a body (an empty 429, say) is an empty body, not
        // a failed exchange.
        if matches!(response.body(), ResponseBody::Empty) {
            return Ok(Reply {
                status,
                body: bytes,
                content_type,
                retry_after,
            });
        }
        let mut stream = response.stream().map_err(|_| CallFailure::Unreachable)?;
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|_| CallFailure::Unreachable)?;
            if bytes.len().saturating_add(chunk.len()) > max_bytes {
                return Err(CallFailure::TooLarge);
            }
            bytes.extend_from_slice(&chunk);
        }
        Ok(Reply {
            status,
            body: bytes,
            content_type,
            retry_after,
        })
    });
    let timeout = std::pin::pin!(Delay::from(std::time::Duration::from_millis(timeout_ms)));
    let result = match select(exchange, timeout).await {
        Either::Left((result, _)) => result,
        Either::Right(_) => Err(CallFailure::Timeout),
    };
    if result.is_err() {
        controller.abort();
    }
    result
}

/// Google's count of the rebuilt body, or `None` when counting failed. No
/// estimate from the body's size bounds its tokens (a token can be a single
/// character), so a window without a count is never reserved or forwarded.
async fn count_input(
    key: &str,
    bundle: &TrialBundle,
    window: &TrialWindow,
    timeout_ms: u64,
) -> Option<u64> {
    let body = count_tokens_body(&bundle.model, &window.outbound);
    match provider_call(
        &bundle.count_tokens_url,
        key,
        &body,
        timeout_ms,
        MAX_COUNT_REPLY_BYTES,
    )
    .await
    {
        Ok(reply) if reply.status == 200 => parse_count_tokens(&reply.body),
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// POST /v1/trial/analyze

async fn analyze(
    req: &mut Request,
    env: &Env,
    config: &TrialConfig,
    bundle: &TrialBundle,
    started: i64,
) -> Response {
    let (response, mut event) = match analyze_inner(req, env, config, bundle, started).await {
        Ok(done) => done,
        Err(_) => {
            log_stage("analyze", "worker_error");
            (
                proxy_response(ProxyCode::TrialUnavailable, None),
                ForwardEvent::new("unknown", "unavailable", 0),
            )
        }
    };
    event.duration_ms = u64::try_from(now_ms().saturating_sub(started)).unwrap_or(0);
    console_log!("{}", line(&event));
    response
}

async fn analyze_inner(
    req: &mut Request,
    env: &Env,
    config: &TrialConfig,
    bundle: &TrialBundle,
    started: i64,
) -> Result<(Response, ForwardEvent)> {
    let (caller, body) = match authenticate(
        req,
        env,
        config,
        TRIAL_ANALYZE_PATH,
        config.body_max_bytes,
        false,
    )
    .await?
    {
        Ok(authenticated) => authenticated,
        Err(code) => {
            let mut event = ForwardEvent::new("unknown", "auth_failed", 0);
            event.detail = Some(code.code());
            return Ok((proxy_response(code, None), event));
        }
    };
    let lane = caller.lane.as_str();
    let window = match parse_window(&body, bundle, config.body_max_bytes) {
        Ok(window) => window,
        Err(RequestError::TooLarge) => {
            return Ok((
                proxy_response(ProxyCode::PayloadTooLarge, None),
                ForwardEvent::new(lane, "payload_too_large", 0),
            ))
        }
        Err(RequestError::Invalid(reason)) => {
            let mut event = ForwardEvent::new(lane, "invalid", 0);
            event.detail = Some(reason.as_str());
            return Ok((
                proxy_response(ProxyCode::Refusal(RefusalCode::RequestInvalid), None),
                event,
            ));
        }
    };
    drop(body);
    let mut event = ForwardEvent::new(lane, "unavailable", 0);
    event.feature = Some(window.feature.as_str());
    let Ok(key) = env.secret(GEMINI_API_KEY) else {
        log_config_error(ConfigError {
            field: ConfigField::GeminiApiKey,
            reason: ConfigReason::Missing,
        });
        return Ok((proxy_response(ProxyCode::TrialUnavailable, None), event));
    };
    let key = key.to_string();

    // Plan the whole exchange to end before the device's own budget does.
    let plan = plan(started, window.call_timeout_seconds);
    let Some(input_tokens) = count_input(&key, bundle, &window, plan.count_timeout_ms).await else {
        // Nothing reserved, nothing forwarded, no unit consumed.
        event.detail = Some("count_failed");
        return Ok((
            proxy_response(
                ProxyCode::TrialUnavailable,
                Some(COUNT_FAILED_RETRY_AFTER_SECONDS),
            ),
            event,
        ));
    };
    event.count = "counted";
    event.input_tokens = Some(input_tokens);
    // Sizes the reservation's lock; the forward itself is re-planned after
    // admission.
    let Some(lock_budget_ms) = forward_budget_ms(plan, now_ms()) else {
        event.outcome = "timeout";
        event.detail = Some("budget_spent_before_forward");
        return Ok((proxy_response(ProxyCode::ProviderTimeout, None), event));
    };
    let Ok(reservation_id) = random_urlsafe_token(18) else {
        return Ok((proxy_response(ProxyCode::TrialUnavailable, None), event));
    };
    let admit = admit_request(
        reservation_id.clone(),
        &caller.subject,
        caller.lane,
        &window,
        bundle,
        input_tokens,
        lock_budget_ms,
    );
    let decision =
        match ledger_exchange::<AdmitResponse>(env, "/admit", &admit, admit_deadline_ms(plan), 0)
            .await
        {
            Ok(response) => response.decision,
            Err(ExchangeError::Unavailable) => {
                return Ok((proxy_response(ProxyCode::TrialUnavailable, None), event))
            }
        };
    let reserved_micros = match decision {
        Decision::Refused {
            code,
            mode,
            retry_after_seconds,
            pause,
        } => {
            event.outcome = code.as_str();
            event.mode = Some(mode.as_str());
            event.detail = pause.map(|pause| pause.as_str());
            return Ok((
                proxy_response(ProxyCode::Refusal(code), retry_after_seconds),
                event,
            ));
        }
        Decision::Admitted {
            reserved_micros,
            mode,
            ..
        } => {
            event.admitted = true;
            event.mode = Some(mode.as_str());
            event.reserved_micros = Some(reserved_micros);
            reserved_micros
        }
    };

    let call = match forward_budget_ms(plan, now_ms()) {
        Some(budget_ms) => {
            provider_call(
                &bundle.generate_url,
                &key,
                &window.outbound_bytes,
                budget_ms,
                MAX_PROVIDER_BODY_BYTES,
            )
            .await
        }
        // Admission ate the forward's time: nothing is sent, nothing charged.
        None => Err(CallFailure::BudgetSpent),
    };
    let (outcome, response) = match call {
        Ok(reply) => {
            event.outcome = status_family(reply.status);
            event.provider_status = Some(reply.status);
            let outcome = classify_reply(reply.status, &reply.body);
            if let SettleOutcome::Usage { usage, .. } = outcome {
                event.output_tokens = Some(usage.output_tokens);
            }
            (outcome, provider_response(reply))
        }
        Err(failure) => {
            let (class, code, outcome_name) = match failure {
                CallFailure::Timeout => (
                    Some(AmbiguousClass::Timeout),
                    ProxyCode::ProviderTimeout,
                    "timeout",
                ),
                CallFailure::Unreachable => (
                    Some(AmbiguousClass::Unreachable),
                    ProxyCode::ProviderUnreachable,
                    "unreachable",
                ),
                CallFailure::TooLarge => (
                    Some(AmbiguousClass::BodyTooLarge),
                    ProxyCode::ProviderBodyTooLarge,
                    "body_too_large",
                ),
                CallFailure::NotDispatched => (None, ProxyCode::TrialUnavailable, "unavailable"),
                CallFailure::BudgetSpent => (None, ProxyCode::ProviderTimeout, "timeout"),
            };
            event.outcome = outcome_name;
            let outcome = match class {
                Some(class) => SettleOutcome::Ambiguous {
                    class,
                    status: None,
                },
                None => SettleOutcome::NotDispatched,
            };
            (outcome, proxy_response(code, None))
        }
    };
    let settle = SettleRequest {
        reservation_id,
        outcome,
    };
    match ledger_exchange::<SettleResult>(
        env,
        "/settle",
        &settle,
        plan.exchange_end_ms,
        SETTLE_FLOOR_MS,
    )
    .await
    {
        Ok(SettleResult::Settled {
            charged_micros,
            overrun_micros,
            ..
        }) => {
            event.charged_micros = Some(charged_micros);
            event.overrun_micros = Some(overrun_micros);
        }
        Ok(SettleResult::AlreadyFinal { charged_micros, .. }) => {
            event.charged_micros = Some(charged_micros);
            event.detail = Some("settled_after_deadline");
        }
        Ok(SettleResult::Unknown) => event.detail = Some("settle_unknown"),
        // The reservation stays charged in full and expires at its deadline.
        Err(ExchangeError::Unavailable) => {
            event.charged_micros = Some(reserved_micros);
            event.detail = Some("settle_lost");
        }
    }
    Ok((response, event))
}

/// The provider's status and body unchanged, its `content-type`, a
/// sanitized `retry-after`, and nothing else from its headers.
fn provider_response(reply: Reply) -> Response {
    let built = (|| -> Result<Response> {
        let headers = Headers::new();
        headers.set(
            "content-type",
            reply.content_type.as_deref().unwrap_or("application/json"),
        )?;
        headers.set("cache-control", "no-store")?;
        if let Some(seconds) = reply.retry_after {
            headers.set("retry-after", &seconds.to_string())?;
        }
        Ok(Response::builder()
            .with_status(reply.status)
            .with_headers(headers)
            .fixed(reply.body))
    })();
    built.unwrap_or_else(|_| proxy_response(ProxyCode::TrialUnavailable, None))
}

// ---------------------------------------------------------------------------
// /v1/trial/status

async fn status(
    req: &mut Request,
    env: &Env,
    config: &TrialConfig,
    bundle: &TrialBundle,
    bearer_only: bool,
) -> Response {
    let (response, lane, mode, outcome) =
        match status_inner(req, env, config, bundle, bearer_only).await {
            Ok(done) => done,
            Err(_) => (
                proxy_response(ProxyCode::TrialUnavailable, None),
                "unknown",
                None,
                "unavailable",
            ),
        };
    console_log!(
        "{}",
        line(&StatusEvent {
            event: "trial_status",
            lane,
            mode,
            outcome,
        })
    );
    response
}

async fn status_inner(
    req: &mut Request,
    env: &Env,
    config: &TrialConfig,
    bundle: &TrialBundle,
    bearer_only: bool,
) -> Result<(Response, &'static str, Option<&'static str>, &'static str)> {
    let (caller, body) = match authenticate(
        req,
        env,
        config,
        TRIAL_STATUS_PATH,
        MAX_STATUS_BODY_BYTES,
        bearer_only,
    )
    .await?
    {
        Ok(authenticated) => authenticated,
        Err(code) => return Ok((proxy_response(code, None), "unknown", None, code.code())),
    };
    let lane = caller.lane.as_str();
    // The signed payload is `{}`; the bearer may send nothing.
    let empty_object = matches!(
        serde_json::from_slice::<serde_json::Value>(&body),
        Ok(serde_json::Value::Object(ref map)) if map.is_empty()
    );
    if !(empty_object || (caller.lane == Lane::Bearer && body.is_empty())) {
        return Ok((
            proxy_response(ProxyCode::Refusal(RefusalCode::RequestInvalid), None),
            lane,
            None,
            "invalid",
        ));
    }
    let now = now_ms();
    let view: StatusView = if config.ledger.mode_at(now) == config::Mode::Open {
        crate::ledger::open_mode_status(&config.ledger)
    } else {
        let (smallest_max_output_tokens, forward_budget_ms) = status_window(bundle, now);
        let request = StatusRequest {
            subject: caller.subject,
            lane: caller.lane,
            model: bundle.model.clone(),
            smallest_max_output_tokens,
            forward_budget_ms,
        };
        match ledger_exchange::<StatusView>(
            env,
            "/status",
            &request,
            now + STATUS_EXCHANGE_BUDGET_MS,
            0,
        )
        .await
        {
            Ok(view) => view,
            Err(ExchangeError::Unavailable) => {
                return Ok((
                    proxy_response(ProxyCode::TrialUnavailable, None),
                    lane,
                    None,
                    "unavailable",
                ))
            }
        }
    };
    let body = serde_json::to_vec(&StatusBody {
        mode: view.mode.as_str(),
        units_remaining: view.units_remaining,
        starts_at: config.mode_starts_at.clone(),
        month_paused: view.month_paused,
    })?;
    Ok((
        json_response(200, body)?,
        lane,
        Some(view.mode.as_str()),
        "ok",
    ))
}

// ---------------------------------------------------------------------------
// App Attest registration (the AdAnalysisWorker flow, against this worker's
// own D1: a key registered with another service is unknown here).

#[derive(Deserialize)]
struct ChallengeRequest {
    install_id: String,
    purpose: String,
}

#[derive(Deserialize)]
struct RegisterRequest {
    install_id: String,
    key_id: String,
    challenge_id: String,
    challenge: String,
    attestation_object: String,
}

fn registration(status: u16, code: &'static str) -> Result<Response> {
    Ok(proxy_response(
        ProxyCode::Registration { status, code },
        None,
    ))
}

async fn read_json<T: for<'de> Deserialize<'de>>(
    req: &mut Request,
    max_bytes: usize,
) -> Result<std::result::Result<T, Response>> {
    let Some(bytes) = read_limited(req, max_bytes).await? else {
        return Ok(Err(proxy_response(ProxyCode::PayloadTooLarge, None)));
    };
    match serde_json::from_slice(&bytes) {
        Ok(body) => Ok(Ok(body)),
        Err(_) => Ok(Err(proxy_response(
            ProxyCode::Registration {
                status: 400,
                code: "invalid_json",
            },
            None,
        ))),
    }
}

fn challenge_source_token(
    req: &Request,
    env: &Env,
) -> Result<std::result::Result<String, ChallengeSourceFailure>> {
    let mut signal = None;
    for name in ["cf-connecting-ip", "true-client-ip"] {
        if let Some(value) = req.headers().get(name)? {
            if !value.trim().is_empty() {
                signal = Some(value.trim().to_string());
                break;
            }
        }
    }
    let Some(signal) = signal else {
        return Ok(Err(ChallengeSourceFailure::MissingSignal));
    };
    let secret = env
        .secret(CHALLENGE_SOURCE_HASH_KEY)
        .ok()
        .map(|secret| secret.to_string());
    let environment = env
        .var("APP_ATTEST_ENVIRONMENT")
        .map(|value| value.to_string())
        .unwrap_or_default();
    match config::challenge_source_key(
        secret.as_deref(),
        &environment,
        DEVELOPMENT_CHALLENGE_SOURCE_HASH_KEY,
    ) {
        Ok(key) => Ok(Ok(keyed_source_token(&key, &signal))),
        Err(reason) => {
            log_config_error(ConfigError {
                field: ConfigField::ChallengeSourceHashKey,
                reason,
            });
            Ok(Err(ChallengeSourceFailure::KeyUnavailable))
        }
    }
}

async fn challenge(req: &mut Request, env: &Env) -> Result<Response> {
    let Ok(db) = env.d1(TRIAL_DB) else {
        return Ok(proxy_response(ProxyCode::TrialUnavailable, None));
    };
    let body = match read_json::<ChallengeRequest>(req, MAX_CHALLENGE_REQUEST_BODY_BYTES).await? {
        Ok(body) => body,
        Err(response) => return Ok(response),
    };
    // Checked before anything is pruned, counted or stored.
    if !identifiers::is_install_id(&body.install_id) {
        return Ok(proxy_response(
            ProxyCode::Refusal(RefusalCode::RequestInvalid),
            None,
        ));
    }
    if body.purpose != REGISTER_PURPOSE {
        return registration(400, "invalid_challenge_request");
    }
    let now = now_ms() / 1_000;
    let _ = storage::prune_challenges_before(&db, now.saturating_sub(CHALLENGE_RETENTION_SECONDS))
        .await;
    let _ = storage::prune_challenge_source_buckets_before(
        &db,
        now.saturating_sub(CHALLENGE_SOURCE_BUCKET_RETENTION_SECONDS),
    )
    .await;
    let source_token = match challenge_source_token(req, env)? {
        Ok(token) => token,
        Err(failure) => return Ok(proxy_response(failure.proxy_code(), None)),
    };
    let count = storage::increment_challenge_source_bucket(
        &db,
        &source_token,
        challenge_bucket_start(now),
        now,
    )
    .await?;
    if !source_challenge_allows_after_increment(count) {
        return registration(429, "challenge_rate_limited");
    }
    let (Ok(challenge_id), Ok(challenge)) = (
        random_urlsafe_token(CHALLENGE_ID_BYTES),
        random_urlsafe_token(CHALLENGE_BYTES),
    ) else {
        return Ok(proxy_response(ProxyCode::TrialUnavailable, None));
    };
    let Some(expires_at) = now.checked_add(CHALLENGE_TTL_SECONDS) else {
        return Ok(proxy_response(ProxyCode::TrialUnavailable, None));
    };
    let admitted = storage::insert_challenge_within_limits(
        &db,
        &challenge_id,
        &challenge,
        &body.purpose,
        &body.install_id,
        now,
        expires_at,
        now.saturating_sub(CHALLENGE_LIMIT_WINDOW_SECONDS),
    )
    .await?;
    if !admitted {
        return registration(429, "challenge_rate_limited");
    }
    json_response(
        200,
        serde_json::to_vec(&serde_json::json!({
            "challenge_id": challenge_id,
            "challenge": challenge,
        }))?,
    )
}

async fn register(req: &mut Request, env: &Env, config: &TrialConfig) -> Result<Response> {
    let Ok(db) = env.d1(TRIAL_DB) else {
        return Ok(proxy_response(ProxyCode::TrialUnavailable, None));
    };
    let body = match read_json::<RegisterRequest>(req, MAX_REGISTER_REQUEST_BODY_BYTES).await? {
        Ok(body) => body,
        Err(response) => return Ok(response),
    };
    // Checked before any lookup or write: only these shapes are stored.
    let well_formed = identifiers::is_install_id(&body.install_id)
        && identifiers::is_challenge_id(&body.challenge_id)
        && identifiers::is_challenge(&body.challenge);
    let Some(key_id) = identifiers::key_id(&body.key_id).filter(|_| well_formed) else {
        return Ok(proxy_response(
            ProxyCode::Refusal(RefusalCode::RequestInvalid),
            None,
        ));
    };
    if body.attestation_object.is_empty() {
        return registration(400, "invalid_register_request");
    }
    let now = now_ms() / 1_000;
    let key_count = storage::app_attest_key_count_since(
        &db,
        &body.install_id,
        now.saturating_sub(APP_ATTEST_KEY_LIMIT_WINDOW_SECONDS),
    )
    .await?;
    if key_count >= MAX_APP_ATTEST_KEYS_PER_INSTALL_PER_DAY
        && storage::key(&db, &body.install_id, &key_id)
            .await?
            .is_none()
    {
        return registration(429, "app_attest_registration_rate_limited");
    }
    let Some(challenge) = storage::challenge(&db, &body.challenge_id).await? else {
        return registration(401, "invalid_challenge");
    };
    if challenge.install_id != body.install_id
        || challenge.purpose != REGISTER_PURPOSE
        || challenge.consumed_at.is_some()
        || challenge.expires_at < now
        || challenge.challenge_hash != challenge_hash(&body.challenge)
    {
        return registration(401, "invalid_challenge");
    }
    if !storage::mark_challenge_consumed(&db, &body.challenge_id, now).await? {
        return registration(401, "invalid_challenge");
    }
    let verified = match verify_attestation(
        &body.attestation_object,
        &body.challenge,
        &config.app_id,
        &key_id,
        &config.app_attest_environment,
        now,
    ) {
        Ok(verified) => verified,
        Err(error) => return registration(401, error.code()),
    };
    storage::upsert_key(
        &db,
        &body.install_id,
        &key_id,
        &verified.public_key,
        &config.app_id,
        &config.app_attest_environment,
        now,
    )
    .await?;
    json_response(200, br#"{"message":"registered"}"#.to_vec())
}
