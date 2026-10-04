//! Daily admission caps: the per-day limiter Durable Object and the client
//! side that admits a submit attempt against its two scopes (the caller's
//! object, then the global object) and gives confirmed admissions back when
//! the attempt exits before the run-start boundary.
//!
//! Accounting rule: usage counts started runs and legacy inline runs, plus
//! provisional admissions for attempts still in flight. A credit refusal, a
//! global refusal after a caller admit, or a persistence failure before the
//! run task is scheduled must leave usage where it was — best effort, with
//! every failure counted and logged, never retried (the release route is a
//! plain decrement, so a lost response cannot be told from a lost write).

use worker::{
    console_error, durable_object, wasm_bindgen, DurableObject, Env, Headers, Method, Request,
    RequestInit, Response, Result, SqlStorage, SqlStorageValue, State,
};

use crate::counters;
use crate::route::JSON_CONTENT_TYPE;
use crate::types::ErrorResponse;
use crate::usage::{
    release_counter_deltas, usage_limiter_route, AcquiredAdmissions, AdmissionScope,
    ScopeReleaseOutcome, UsageAdmitRequest, UsageLimitProfile, UsageLimiterRoute,
    UsageReleaseRequest, USAGE_LIMITER_ADMIT_PATH, USAGE_LIMITER_BINDING,
    USAGE_LIMITER_RELEASE_PATH,
};
use crate::validation::DailyUsage;
use crate::worker_app::{json_error, json_response, json_success};

const USAGE_LIMITER_ORIGIN: &str = "https://usage-limiter.opencast.internal";

/// Admits one attempt against both scopes. `Ok(Err(response))` is the
/// client-facing refusal (429 cap denial or 503 limiter error) with every
/// confirmed scope already given back; `Err` is a thrown limiter call,
/// likewise after cleanup of anything confirmed before it. A global call
/// whose outcome is unknown is logged and never decremented: only the
/// caller's confirmed admission is unwound.
pub(crate) async fn admit_spend_caps(
    env: &Env,
    caller: AdmissionScope,
    global: AdmissionScope,
) -> Result<std::result::Result<AcquiredAdmissions, Response>> {
    match admit_usage(env, &caller).await? {
        AdmitOutcome::Admitted => {}
        AdmitOutcome::Refused(response) => return Ok(Err(response)),
    }
    let acquired = AcquiredAdmissions::first(caller);
    match admit_usage(env, &global).await {
        Ok(AdmitOutcome::Admitted) => {
            let mut acquired = acquired;
            acquired.push(global);
            Ok(Ok(acquired))
        }
        Ok(AdmitOutcome::Refused(response)) => {
            release_admissions(env, acquired).await;
            Ok(Err(response))
        }
        Err(error) => {
            console_error!(
                "transcript-analysis global admission outcome unknown ({}); caller admission released, global left as is: {error}",
                global.profile.label()
            );
            release_admissions(env, acquired).await;
            Err(error)
        }
    }
}

/// Best-effort cleanup of every confirmed scope, in acquisition order. A
/// failed release never skips the remaining scopes; the counters record
/// full versus partial cleanup and the caller's response is untouched.
pub(crate) async fn release_admissions(env: &Env, acquired: AcquiredAdmissions) {
    let mut outcomes = Vec::with_capacity(2);
    for scope in acquired.into_scopes() {
        let outcome = match release_usage(env, &scope).await {
            Ok(true) => ScopeReleaseOutcome::Released,
            Ok(false) => {
                console_error!(
                    "transcript-analysis admission release refused by the {} limiter",
                    scope.profile.label()
                );
                ScopeReleaseOutcome::Failed
            }
            Err(error) => {
                console_error!(
                    "transcript-analysis admission release lost for the {} limiter: {error}",
                    scope.profile.label()
                );
                ScopeReleaseOutcome::Failed
            }
        };
        outcomes.push(outcome);
    }
    counters::bump(env, &release_counter_deltas(&outcomes)).await;
}

enum AdmitOutcome {
    Admitted,
    Refused(Response),
}

async fn admit_usage(env: &Env, scope: &AdmissionScope) -> Result<AdmitOutcome> {
    let body = serde_json::to_string(&UsageAdmitRequest {
        estimated_input_tokens: scope.estimated_input_tokens,
        profile: scope.profile,
    })?;
    let mut response =
        limiter_post(env, &scope.object_name, USAGE_LIMITER_ADMIT_PATH, body).await?;
    let status = response.status_code();
    if status == 200 {
        let _: DailyUsage = response.json().await?;
        return Ok(AdmitOutcome::Admitted);
    }

    let error = response
        .json::<ErrorResponse>()
        .await
        .unwrap_or_else(|_| ErrorResponse::new("usage_limiter_error"));
    if status == 429 {
        // A cap denial, keyed by the profile that refused; limiter errors
        // (503) are not denials and are not counted.
        counters::bump(env, &[(cap_denial_counter(scope.profile), 1)]).await;
    }
    Ok(AdmitOutcome::Refused(json_response(
        if status == 429 { 429 } else { 503 },
        error,
    )?))
}

/// `Ok(true)` only on a 200: the decrement landed. Anything else leaves the
/// scope charged.
async fn release_usage(env: &Env, scope: &AdmissionScope) -> Result<bool> {
    let body = serde_json::to_string(&UsageReleaseRequest {
        estimated_input_tokens: scope.estimated_input_tokens,
        profile: scope.profile,
    })?;
    let response = limiter_post(env, &scope.object_name, USAGE_LIMITER_RELEASE_PATH, body).await?;
    Ok(response.status_code() == 200)
}

async fn limiter_post(env: &Env, object_name: &str, path: &str, body: String) -> Result<Response> {
    let namespace = env.durable_object(USAGE_LIMITER_BINDING)?;
    let stub = namespace.get_by_name(object_name)?;
    let headers = Headers::new();
    headers.set("content-type", JSON_CONTENT_TYPE)?;
    let mut init = RequestInit::new();
    init.with_method(Method::Post)
        .with_headers(headers)
        .with_body(Some(body.into()));
    let request = Request::new_with_init(&format!("{USAGE_LIMITER_ORIGIN}{path}"), &init)?;
    stub.fetch_with_request(request).await
}

fn cap_denial_counter(profile: UsageLimitProfile) -> &'static str {
    match profile {
        UsageLimitProfile::Bearer => counters::CAP_DENIALS_BEARER,
        UsageLimitProfile::AppAttestKey => counters::CAP_DENIALS_APP_ATTEST,
        UsageLimitProfile::Global => counters::CAP_DENIALS_GLOBAL,
    }
}

/// Objects are minted per subject and day and never addressed again once
/// their day passes, so each schedules its own storage wipe: an alarm ~48 h
/// after the first write (safely past any timezone or day-boundary read)
/// deletes everything. Pure GC — the object name is never reused, so live
/// limits cannot change.
const USAGE_LIMITER_CLEANUP_DELAY: std::time::Duration =
    std::time::Duration::from_secs(48 * 60 * 60);

#[durable_object(alarm)]
pub struct TranscriptAnalysisUsageLimiter {
    state: State,
    sql: SqlStorage,
}

impl DurableObject for TranscriptAnalysisUsageLimiter {
    fn new(state: State, _env: Env) -> Self {
        let sql = state.storage().sql();
        sql.exec(
            "CREATE TABLE IF NOT EXISTS daily_usage (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                request_count INTEGER NOT NULL,
                estimated_input_tokens INTEGER NOT NULL
            );",
            None,
        )
        .expect("create usage limiter table");
        Self { state, sql }
    }

    async fn fetch(&self, mut req: Request) -> Result<Response> {
        if req.method() != Method::Post {
            return json_error(405, ErrorResponse::new("method_not_allowed"));
        }
        match usage_limiter_route(&req.path()) {
            Some(UsageLimiterRoute::Admit) => self.admit(&mut req).await,
            Some(UsageLimiterRoute::Release) => self.release(&mut req).await,
            None => json_error(404, ErrorResponse::new("not_found")),
        }
    }

    async fn alarm(&self) -> Result<Response> {
        // DROP first: delete_all clears the object's storage, and dropping
        // the table explicitly keeps the wipe complete even if the SQLite
        // backend's delete_all semantics ever exclude SQL tables.
        self.sql.exec("DROP TABLE IF EXISTS daily_usage;", None)?;
        self.state.storage().delete_all().await?;
        self.state.storage().delete_alarm().await?;
        Response::ok("")
    }
}

impl TranscriptAnalysisUsageLimiter {
    async fn admit(&self, req: &mut Request) -> Result<Response> {
        let admit_request = match req.json::<UsageAdmitRequest>().await {
            Ok(request) => request,
            Err(_) => return json_error(400, ErrorResponse::new("malformed_json")),
        };
        let current_usage = self.current_usage()?;
        let next_usage = match current_usage.admitting_with_limits(
            admit_request.estimated_input_tokens,
            admit_request.profile.limits(),
        ) {
            Ok(usage) => usage,
            Err(error) => return json_error(429, ErrorResponse::new(error.code())),
        };
        self.write_usage(&next_usage)?;
        self.schedule_cleanup().await?;
        json_success(200, &next_usage)
    }

    /// Subtracts one confirmed admission, saturating at zero. A release that
    /// changes nothing (an object already at zero, or one its cleanup alarm
    /// has wiped) writes nothing, so it can neither recreate storage nor
    /// schedule a fresh cleanup — the object's lifetime is set by its first
    /// admit alone.
    async fn release(&self, req: &mut Request) -> Result<Response> {
        let release_request = match req.json::<UsageReleaseRequest>().await {
            Ok(request) => request,
            Err(_) => return json_error(400, ErrorResponse::new("malformed_json")),
        };
        let current_usage = self.current_usage()?;
        let next_usage = current_usage.releasing(release_request.estimated_input_tokens);
        if next_usage != current_usage {
            self.write_usage(&next_usage)?;
        }
        json_success(200, &next_usage)
    }

    async fn schedule_cleanup(&self) -> Result<()> {
        if self.state.storage().get_alarm().await?.is_none() {
            self.state
                .storage()
                .set_alarm(USAGE_LIMITER_CLEANUP_DELAY)
                .await?;
        }
        Ok(())
    }

    fn current_usage(&self) -> Result<DailyUsage> {
        let rows: Vec<DailyUsageRow> = self
            .sql
            .exec(
                "SELECT request_count, estimated_input_tokens FROM daily_usage WHERE id = 1 LIMIT 1;",
                None,
            )?
            .to_array()?;
        Ok(rows
            .first()
            .map(DailyUsageRow::daily_usage)
            .unwrap_or_default())
    }

    fn write_usage(&self, usage: &DailyUsage) -> Result<()> {
        self.sql.exec(
            "INSERT INTO daily_usage (id, request_count, estimated_input_tokens)
             VALUES (1, ?, ?)
             ON CONFLICT(id) DO UPDATE SET
                request_count = excluded.request_count,
                estimated_input_tokens = excluded.estimated_input_tokens;",
            vec![
                SqlStorageValue::Integer(usage.request_count as i64),
                SqlStorageValue::Integer(usage.estimated_input_tokens as i64),
            ],
        )?;
        Ok(())
    }
}

#[derive(serde::Deserialize)]
struct DailyUsageRow {
    request_count: i64,
    estimated_input_tokens: i64,
}

impl DailyUsageRow {
    fn daily_usage(&self) -> DailyUsage {
        DailyUsage {
            request_count: self.request_count.max(0) as u64,
            estimated_input_tokens: self.estimated_input_tokens.max(0) as u64,
        }
    }
}
