use std::time::Duration;

use futures_util::future::Either;
use futures_util::StreamExt;
use worker::{
    console_error, console_log, AbortController, Cache, Context, Date, Delay, Env, Fetch, Headers,
    Method, Request, RequestInit, Response, Result,
};

use crate::cache_policy::{cache_ttl_seconds, lookup_cache_key, search_cache_key};
use crate::logging::{log_line, RequestLog};
use crate::podcast_index::{
    auth_token, lookup_url, parse_lookup_response, parse_search_response, search_url,
    DIRECTORY_USER_AGENT,
};
use crate::route::{route_request, RouteAction, StaticResponse, JSON_CONTENT_TYPE};
use crate::types::{
    ErrorResponse, LookupResponse, SearchRequest, SearchResponse, DTO_VERSION,
    ERROR_BINDING_MISSING, ERROR_DISABLED, ERROR_INVALID_CONTENT_TYPE, ERROR_INVALID_JSON,
    ERROR_INVALID_QUERY, ERROR_NOT_FOUND, ERROR_PAYLOAD_TOO_LARGE, ERROR_RATE_LIMITED,
    ERROR_SECRET_MISSING, ERROR_UPSTREAM_MALFORMED, ERROR_UPSTREAM_STATUS, ERROR_UPSTREAM_TIMEOUT,
    ERROR_UPSTREAM_TOO_LARGE, ERROR_UPSTREAM_UNREACHABLE, LOOKUP_CACHE_TTL_CAP_SECONDS,
    MAX_REQUEST_BODY_BYTES, MAX_UPSTREAM_BODY_BYTES, SEARCH_CACHE_TTL_CAP_SECONDS,
    UPSTREAM_TIMEOUT_MS,
};
use crate::validation::{is_json_content_type, normalized_query};

const ENABLED_FLAG_VAR: &str = "PUBLIC_PODCAST_DIRECTORY_ENABLED";
const API_KEY_SECRET: &str = "PODCAST_INDEX_API_KEY";
const API_SECRET_SECRET: &str = "PODCAST_INDEX_API_SECRET";
const CLIENT_RATE_LIMITER_BINDING: &str = "CLIENT_RATE_LIMITER";
const UPSTREAM_RATE_LIMITER_BINDING: &str = "UPSTREAM_RATE_LIMITER";

const ROUTE_SEARCH: &str = "search";
const ROUTE_LOOKUP: &str = "lookup";
const ROUTE_HEALTH: &str = "health";
const ROUTE_STATIC: &str = "static";

const CACHE_NONE: &str = "none";
const CACHE_HIT: &str = "hit";
const CACHE_MISS: &str = "miss";
const CACHE_STORE: &str = "store";

pub async fn handle_request(req: Request, env: Env, ctx: Context) -> Result<Response> {
    let method = req.method().to_string();
    let path = req.path();

    match route_request(&method, &path) {
        RouteAction::Static(static_response) => {
            log_request(
                ROUTE_STATIC,
                static_response.status,
                CACHE_NONE,
                None,
                None,
                None,
            );
            render_static(static_response)
        }
        RouteAction::Health => {
            let body = crate::types::HealthResponse {
                message: "ok".to_string(),
                enabled: directory_enabled(&env),
            };
            log_request(ROUTE_HEALTH, 200, CACHE_NONE, None, None, None);
            json_success(200, &body)
        }
        RouteAction::Search => {
            let served = handle_search(req, &env, &ctx).await?;
            finish(ROUTE_SEARCH, served)
        }
        RouteAction::LookupByAppleId(apple_id) => {
            let served = handle_lookup(apple_id, &req, &env, &ctx).await?;
            finish(ROUTE_LOOKUP, served)
        }
    }
}

struct Served {
    response: Response,
    cache: &'static str,
    provider_latency_ms: Option<u64>,
    result_count: Option<usize>,
    error_class: Option<&'static str>,
}

impl Served {
    fn error(status: u16, code: &'static str) -> Result<Self> {
        Self::error_response(status, ErrorResponse::new(code), code)
    }

    fn error_response(status: u16, body: ErrorResponse, class: &'static str) -> Result<Self> {
        Ok(Self {
            response: json_error(status, &body)?,
            cache: CACHE_NONE,
            provider_latency_ms: None,
            result_count: None,
            error_class: Some(class),
        })
    }
}

fn finish(route: &'static str, served: Served) -> Result<Response> {
    log_request(
        route,
        served.response.status_code(),
        served.cache,
        served.provider_latency_ms,
        served.result_count,
        served.error_class,
    );
    Ok(served.response)
}

async fn handle_search(mut req: Request, env: &Env, ctx: &Context) -> Result<Served> {
    if !directory_enabled(env) {
        return Served::error(503, ERROR_DISABLED);
    }

    let content_type = req.headers().get("content-type")?.unwrap_or_default();
    if !is_json_content_type(&content_type) {
        return Served::error(400, ERROR_INVALID_CONTENT_TYPE);
    }

    let body = match read_limited_body(&mut req, MAX_REQUEST_BODY_BYTES).await? {
        Ok(body) => body,
        Err(served) => return Ok(served),
    };
    let request: SearchRequest = match serde_json::from_slice(&body) {
        Ok(request) => request,
        Err(_) => return Served::error(400, ERROR_INVALID_JSON),
    };
    let Some(query) = normalized_query(&request.query) else {
        return Served::error(400, ERROR_INVALID_QUERY);
    };

    serve_via_upstream(
        env,
        ctx,
        &req,
        ROUTE_SEARCH,
        search_cache_key(&query),
        search_url(&query),
        SEARCH_CACHE_TTL_CAP_SECONDS,
        |body| {
            let entries = parse_search_response(body).map_err(|_| ())?;
            let count = entries.len();
            let response = SearchResponse {
                version: DTO_VERSION,
                results: entries,
            };
            Ok(Some((
                serde_json::to_vec(&response).map_err(|_| ())?,
                count,
            )))
        },
    )
    .await
}

async fn handle_lookup(apple_id: u64, req: &Request, env: &Env, ctx: &Context) -> Result<Served> {
    if !directory_enabled(env) {
        return Served::error(503, ERROR_DISABLED);
    }

    serve_via_upstream(
        env,
        ctx,
        req,
        ROUTE_LOOKUP,
        lookup_cache_key(apple_id),
        lookup_url(apple_id),
        LOOKUP_CACHE_TTL_CAP_SECONDS,
        |body| match parse_lookup_response(body).map_err(|_| ())? {
            Some(entry) => {
                let response = LookupResponse {
                    version: DTO_VERSION,
                    result: entry,
                };
                Ok(Some((serde_json::to_vec(&response).map_err(|_| ())?, 1)))
            }
            None => Ok(None),
        },
    )
    .await
}

/// The shared cache → rate limit → upstream → normalize → cache-store
/// pipeline. `build_body` returns the serialized client body plus a
/// result count, `Ok(None)` for a non-cacheable 404 (lookup miss), and
/// `Err(())` for malformed upstream data.
#[allow(clippy::too_many_arguments)]
async fn serve_via_upstream(
    env: &Env,
    ctx: &Context,
    req: &Request,
    route: &'static str,
    cache_key: String,
    upstream_url: String,
    ttl_cap_seconds: u64,
    build_body: impl FnOnce(&[u8]) -> std::result::Result<Option<(Vec<u8>, usize)>, ()>,
) -> Result<Served> {
    let cache = Cache::default();
    if let Some(cached) = cache.get(cache_key.as_str(), false).await? {
        return Ok(Served {
            response: cached,
            cache: CACHE_HIT,
            provider_latency_ms: None,
            result_count: None,
            error_class: None,
        });
    }

    let client_key = format!("{}:{route}", client_ip(req));
    match admit(env, CLIENT_RATE_LIMITER_BINDING, client_key).await {
        Ok(true) => {}
        Ok(false) => return Served::error(429, ERROR_RATE_LIMITED),
        Err(body) => return Served::error_response(503, body, ERROR_BINDING_MISSING),
    }
    match admit(env, UPSTREAM_RATE_LIMITER_BINDING, route.to_string()).await {
        Ok(true) => {}
        Ok(false) => return Served::error(429, ERROR_RATE_LIMITED),
        Err(body) => return Served::error_response(503, body, ERROR_BINDING_MISSING),
    }

    let api_key = match required_secret(env, API_KEY_SECRET) {
        Ok(secret) => secret,
        Err(body) => return Served::error_response(503, body, ERROR_SECRET_MISSING),
    };
    let api_secret = match required_secret(env, API_SECRET_SECRET) {
        Ok(secret) => secret,
        Err(body) => return Served::error_response(503, body, ERROR_SECRET_MISSING),
    };

    let started_ms = Date::now().as_millis();
    let upstream = fetch_upstream(&upstream_url, &api_key, &api_secret).await;
    let provider_latency_ms = Some(Date::now().as_millis().saturating_sub(started_ms));

    let (upstream_body, upstream_cache_control) = match upstream {
        Ok(outcome) => outcome,
        Err(class) => {
            let mut served = Served::error(502, class)?;
            served.provider_latency_ms = provider_latency_ms;
            return Ok(served);
        }
    };

    let (serialized, result_count) = match build_body(&upstream_body) {
        Ok(Some(built)) => built,
        Ok(None) => {
            let mut served = Served::error(404, ERROR_NOT_FOUND)?;
            served.provider_latency_ms = provider_latency_ms;
            return Ok(served);
        }
        Err(()) => {
            let mut served = Served::error(502, ERROR_UPSTREAM_MALFORMED)?;
            served.provider_latency_ms = provider_latency_ms;
            return Ok(served);
        }
    };

    let ttl_seconds = cache_ttl_seconds(upstream_cache_control.as_deref(), ttl_cap_seconds);
    let headers = Headers::new();
    headers.set("content-type", JSON_CONTENT_TYPE)?;
    if let Some(ttl_seconds) = ttl_seconds {
        headers.set("cache-control", &format!("public, max-age={ttl_seconds}"))?;
    }
    let mut response = Response::builder()
        .with_status(200)
        .with_headers(headers)
        .fixed(serialized);

    let mut cache_outcome = CACHE_MISS;
    if ttl_seconds.is_some() {
        let cached_copy = response.cloned()?;
        ctx.wait_until(async move {
            let cache = Cache::default();
            if let Err(error) = cache.put(cache_key.as_str(), cached_copy).await {
                console_error!("directory cache write failed: {error:?}");
            }
        });
        cache_outcome = CACHE_STORE;
    }

    Ok(Served {
        response,
        cache: cache_outcome,
        provider_latency_ms,
        result_count: Some(result_count),
        error_class: None,
    })
}

async fn fetch_upstream(
    url: &str,
    api_key: &str,
    api_secret: &str,
) -> std::result::Result<(Vec<u8>, Option<String>), &'static str> {
    let unix_seconds = Date::now().as_millis() / 1_000;
    let headers = Headers::new();
    let prepared = headers
        .set("user-agent", DIRECTORY_USER_AGENT)
        .and_then(|()| headers.set("x-auth-key", api_key))
        .and_then(|()| headers.set("x-auth-date", &unix_seconds.to_string()))
        .and_then(|()| {
            headers.set(
                "authorization",
                &auth_token(api_key, api_secret, unix_seconds),
            )
        });
    if prepared.is_err() {
        return Err(ERROR_UPSTREAM_UNREACHABLE);
    }

    let mut init = RequestInit::new();
    init.with_method(Method::Get).with_headers(headers);
    let request = Request::new_with_init(url, &init).map_err(|_| ERROR_UPSTREAM_UNREACHABLE)?;

    let controller = AbortController::default();
    let signal = controller.signal();
    let fetch = Fetch::Request(request);
    let fetch_future = fetch.send_with_signal(&signal);
    let timeout = Delay::from(Duration::from_millis(UPSTREAM_TIMEOUT_MS));
    futures_util::pin_mut!(fetch_future);
    futures_util::pin_mut!(timeout);

    let mut response = match futures_util::future::select(fetch_future, timeout).await {
        Either::Left((result, _)) => result.map_err(|_| ERROR_UPSTREAM_UNREACHABLE)?,
        Either::Right(((), _)) => {
            controller.abort();
            return Err(ERROR_UPSTREAM_TIMEOUT);
        }
    };

    if response.status_code() != 200 {
        return Err(ERROR_UPSTREAM_STATUS);
    }

    let cache_control = response.headers().get("cache-control").ok().flatten();
    let mut stream = response.stream().map_err(|_| ERROR_UPSTREAM_UNREACHABLE)?;
    let mut body = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|_| ERROR_UPSTREAM_UNREACHABLE)?;
        if body.len() + chunk.len() > MAX_UPSTREAM_BODY_BYTES {
            return Err(ERROR_UPSTREAM_TOO_LARGE);
        }
        body.extend_from_slice(&chunk);
    }

    Ok((body, cache_control))
}

/// Reads at most `max_bytes` of the request body; larger bodies are
/// rejected as 413 without buffering past the cap.
async fn read_limited_body(
    req: &mut Request,
    max_bytes: usize,
) -> Result<std::result::Result<Vec<u8>, Served>> {
    if let Some(declared) = req
        .headers()
        .get("content-length")?
        .and_then(|value| value.parse::<usize>().ok())
    {
        if declared > max_bytes {
            return Ok(Err(Served::error(413, ERROR_PAYLOAD_TOO_LARGE)?));
        }
    }

    let mut stream = req.stream()?;
    let mut body = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        if body.len() + chunk.len() > max_bytes {
            return Ok(Err(Served::error(413, ERROR_PAYLOAD_TOO_LARGE)?));
        }
        body.extend_from_slice(&chunk);
    }
    Ok(Ok(body))
}

/// Fail-closed on a missing binding; fail-open (with a log) on limiter
/// transport errors so the directory doesn't go down with the limiter.
async fn admit(
    env: &Env,
    binding: &'static str,
    key: String,
) -> std::result::Result<bool, ErrorResponse> {
    let limiter = env
        .rate_limiter(binding)
        .map_err(|_| ErrorResponse::with_detail(ERROR_BINDING_MISSING, binding.to_string()))?;
    match limiter.limit(key).await {
        Ok(outcome) => Ok(outcome.success),
        Err(error) => {
            console_error!("rate limiter {binding} admit failed: {error:?}");
            Ok(true)
        }
    }
}

fn client_ip(req: &Request) -> String {
    req.headers()
        .get("cf-connecting-ip")
        .ok()
        .flatten()
        .unwrap_or_else(|| "unknown".to_string())
}

fn directory_enabled(env: &Env) -> bool {
    env.var(ENABLED_FLAG_VAR)
        .map(|value| value.to_string() == "true")
        .unwrap_or(false)
}

fn required_secret(env: &Env, name: &'static str) -> std::result::Result<String, ErrorResponse> {
    env.secret(name)
        .map(|secret| secret.to_string())
        .map_err(|_| ErrorResponse::with_detail(ERROR_SECRET_MISSING, name.to_string()))
}

fn log_request(
    route: &str,
    status: u16,
    cache: &str,
    provider_latency_ms: Option<u64>,
    result_count: Option<usize>,
    error_class: Option<&str>,
) {
    let line = log_line(&RequestLog {
        route,
        status,
        cache,
        provider_latency_ms,
        result_count,
        error_class,
    });
    console_log!("{line}");
}

fn render_static(static_response: StaticResponse) -> Result<Response> {
    let headers = Headers::new();
    for header in &static_response.headers {
        headers.set(header.name, &header.value)?;
    }
    Ok(Response::builder()
        .with_status(static_response.status)
        .with_headers(headers)
        .fixed(static_response.body.into_bytes()))
}

fn json_success(status: u16, body: &impl serde::Serialize) -> Result<Response> {
    let headers = Headers::new();
    headers.set("content-type", JSON_CONTENT_TYPE)?;
    Ok(Response::builder()
        .with_status(status)
        .with_headers(headers)
        .fixed(serde_json::to_vec(body)?))
}

fn json_error(status: u16, body: &ErrorResponse) -> Result<Response> {
    let headers = Headers::new();
    headers.set("content-type", JSON_CONTENT_TYPE)?;
    Ok(Response::builder()
        .with_status(status)
        .with_headers(headers)
        .fixed(serde_json::to_vec(body)?))
}
