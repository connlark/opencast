use crate::route::{
    content_range_header, edge_cacheable, if_none_match_matches,
    json_response as static_json_response, parse_range_header, route_request,
    unsatisfied_content_range_header, Header as StaticHeader, RangeError, RangeSelection,
    RouteAction, StaticResponse, JSON_CONTENT_TYPE, OBJECT_NOT_FOUND_JSON,
    RANGE_NOT_SATISFIABLE_JSON,
};
use worker::{console_error, Cache, Context, Env, Headers, Method, Request, Response, Result};

const MODEL_BUCKET: &str = "MODEL_BUCKET";
const MODEL_OBJECT_PREFIX: &str = "MODEL_OBJECT_PREFIX";
const PUBLIC_MODEL_GATEWAY_ENABLED: &str = "PUBLIC_MODEL_GATEWAY_ENABLED";

struct GatewayConfig {
    object_prefix: String,
    enabled: bool,
}

impl GatewayConfig {
    fn from_env(env: &Env) -> Result<Self> {
        let object_prefix = env.var(MODEL_OBJECT_PREFIX)?.to_string();
        let enabled = env.var(PUBLIC_MODEL_GATEWAY_ENABLED)?.to_string() == "true";
        Ok(Self {
            object_prefix,
            enabled,
        })
    }
}

pub async fn handle_request(req: Request, env: Env, ctx: Context) -> Result<Response> {
    let method = req.method();
    let path = req.path();
    let config = GatewayConfig::from_env(&env)?;
    let gateway = Gateway {
        env: &env,
        ctx: &ctx,
        conditional: RequestConditions::from_request(&req)?,
    };

    match route_request(
        method.as_ref(),
        &path,
        config.enabled,
        &config.object_prefix,
    ) {
        RouteAction::Static(response) => static_response(response),
        RouteAction::Manifest { object_key, head }
        | RouteAction::ManifestSignature { object_key, head } => {
            serve_manifest(&gateway, &object_key, head).await
        }
        RouteAction::Asset { route, head } => {
            serve_asset(
                &gateway,
                &req,
                method,
                &route.object_key,
                route.content_type,
                head,
            )
            .await
        }
    }
}

/// Per-request serving state: the bindings, the invocation context (for
/// background cache writes), and the conditional-request inputs.
struct Gateway<'a> {
    env: &'a Env,
    ctx: &'a Context,
    conditional: RequestConditions,
}

/// The request-derived state conditional serving needs: the `If-None-Match`
/// header and the edge-cache key (the request URL).
struct RequestConditions {
    if_none_match: Option<String>,
    cache_url: String,
}

impl RequestConditions {
    fn from_request(req: &Request) -> Result<Self> {
        Ok(Self {
            if_none_match: req.headers().get("if-none-match")?,
            cache_url: req.url()?.to_string(),
        })
    }

    fn matches(&self, etag: &str) -> bool {
        if_none_match_matches(self.if_none_match.as_deref(), etag)
    }
}

fn not_modified(headers: Headers) -> Result<Response> {
    Ok(Response::builder()
        .with_status(304)
        .with_headers(headers)
        .empty())
}

async fn serve_manifest(gateway: &Gateway<'_>, object_key: &str, head: bool) -> Result<Response> {
    if head {
        let bucket = gateway.env.bucket(MODEL_BUCKET)?;
        let Some(object) = bucket.head(object_key).await? else {
            return json_error(404, OBJECT_NOT_FOUND_JSON);
        };
        let headers = object_headers(&object, JSON_CONTENT_TYPE, object.size(), None)?;
        if gateway.conditional.matches(&object.http_etag()) {
            return not_modified(headers);
        }
        return Ok(Response::builder()
            .with_status(200)
            .with_headers(headers)
            .empty());
    }

    serve_cached_full_body(gateway, object_key, JSON_CONTENT_TYPE).await
}

async fn serve_asset(
    gateway: &Gateway<'_>,
    req: &Request,
    method: Method,
    object_key: &str,
    content_type: &'static str,
    head: bool,
) -> Result<Response> {
    let bucket = gateway.env.bucket(MODEL_BUCKET)?;
    let range_header = req.headers().get("range")?;

    if range_header.is_some() || head {
        let Some(metadata) = bucket.head(object_key).await? else {
            return json_error(404, OBJECT_NOT_FOUND_JSON);
        };
        let size = metadata.size();
        // If-None-Match is evaluated before Range: a matching validator
        // means the client's copy is current, whole or sliced.
        if gateway.conditional.matches(&metadata.http_etag()) {
            let headers = object_headers(&metadata, content_type, size, None)?;
            return not_modified(headers);
        }
        let selection = match parse_range_header(range_header.as_deref(), size) {
            Ok(selection) => selection,
            Err(RangeError::Invalid | RangeError::NotSatisfiable) => {
                return range_not_satisfiable(size)
            }
        };

        return match selection {
            RangeSelection::Full => {
                if head {
                    let headers = object_headers(&metadata, content_type, size, None)?;
                    Ok(Response::builder()
                        .with_status(200)
                        .with_headers(headers)
                        .empty())
                } else {
                    serve_cached_full_body(gateway, object_key, content_type).await
                }
            }
            RangeSelection::Partial(range) => {
                let headers = object_headers(
                    &metadata,
                    content_type,
                    range.length,
                    Some(content_range_header(&range, size)),
                )?;
                if head {
                    return Ok(Response::builder()
                        .with_status(206)
                        .with_headers(headers)
                        .empty());
                }

                let object = bucket
                    .get(object_key)
                    .range(worker::Range::OffsetWithLength {
                        offset: range.start,
                        length: range.length,
                    })
                    .execute()
                    .await?;
                let Some(object) = object else {
                    return json_error(404, OBJECT_NOT_FOUND_JSON);
                };
                let Some(body) = object.body() else {
                    return json_error(404, OBJECT_NOT_FOUND_JSON);
                };
                Ok(Response::builder()
                    .with_status(206)
                    .with_headers(headers)
                    .body(body.response_body()?))
            }
        };
    }

    if method != Method::Get {
        console_error!("unexpected non-GET asset path reached");
        return json_error(405, crate::route::METHOD_NOT_ALLOWED_JSON);
    }

    serve_cached_full_body(gateway, object_key, content_type).await
}

/// GET path for the manifest and whole assets: fronted by the edge Cache API
/// (keyed on the request URL; the stored response's max-age governs expiry),
/// with `If-None-Match` evaluated on both hit and miss. On a miss the R2
/// body is teed: the client branch streams immediately while the cache
/// write runs under `wait_until`, so a several-hundred-MB weight file is
/// never withheld until the edge copy lands, and a refused write is logged
/// rather than turning a servable download into a 500. Objects above the
/// Cache API size ceiling skip the tee entirely. The range path stays
/// direct-R2 — caching sliced bodies is complexity without demonstrated
/// need; revisit if telemetry shows hot ranges.
async fn serve_cached_full_body(
    gateway: &Gateway<'_>,
    object_key: &str,
    content_type: &'static str,
) -> Result<Response> {
    let conditional = &gateway.conditional;
    let cache = Cache::default();
    if let Some(cached) = cache.get(conditional.cache_url.as_str(), false).await? {
        if let Some(etag) = cached.headers().get("etag")? {
            if conditional.matches(&etag) {
                return not_modified(cached.headers().clone());
            }
        }
        return Ok(cached);
    }

    let bucket = gateway.env.bucket(MODEL_BUCKET)?;
    let Some(object) = bucket.get(object_key).execute().await? else {
        return json_error(404, OBJECT_NOT_FOUND_JSON);
    };
    let etag = object.http_etag();
    let size = object.size();
    let headers = object_headers(&object, content_type, size, None)?;
    let Some(body) = object.body() else {
        return json_error(404, OBJECT_NOT_FOUND_JSON);
    };
    let mut response = Response::builder()
        .with_status(200)
        .with_headers(headers)
        .body(body.response_body()?);
    if edge_cacheable(size) {
        match response.cloned() {
            Ok(cached_copy) => {
                let cache_url = conditional.cache_url.clone();
                gateway.ctx.wait_until(async move {
                    if let Err(error) = Cache::default().put(cache_url.as_str(), cached_copy).await
                    {
                        console_error!(
                            "model gateway cache write failed for {cache_url}: {error:?}"
                        );
                    }
                });
            }
            Err(error) => {
                console_error!(
                    "model gateway response tee failed for {}: {error:?}",
                    conditional.cache_url
                );
            }
        }
    }
    if conditional.matches(&etag) {
        return not_modified(response.headers().clone());
    }
    Ok(response)
}

fn object_headers(
    object: &worker::Object,
    content_type: &str,
    content_length: u64,
    content_range: Option<String>,
) -> Result<Headers> {
    let headers = Headers::new();
    object.write_http_metadata(headers.clone())?;
    headers.set("content-type", content_type)?;
    headers.set("content-length", &content_length.to_string())?;
    headers.set("etag", &object.http_etag())?;
    headers.set("accept-ranges", "bytes")?;
    headers.set("cache-control", "public, max-age=3600")?;
    if let Some(content_range) = content_range {
        headers.set("content-range", &content_range)?;
    }
    Ok(headers)
}

fn range_not_satisfiable(object_size: u64) -> Result<Response> {
    let headers = Headers::new();
    headers.set("content-type", JSON_CONTENT_TYPE)?;
    headers.set("accept-ranges", "bytes")?;
    headers.set(
        "content-range",
        &unsatisfied_content_range_header(object_size),
    )?;
    Ok(Response::builder()
        .with_status(416)
        .with_headers(headers)
        .fixed(RANGE_NOT_SATISFIABLE_JSON.as_bytes().to_vec()))
}

fn json_error(status: u16, body: &'static str) -> Result<Response> {
    static_response(static_json_response(status, body))
}

fn static_response(response: StaticResponse) -> Result<Response> {
    let headers = Headers::new();
    for StaticHeader { name, value } in response.headers {
        headers.set(name, &value)?;
    }
    Ok(Response::builder()
        .with_status(response.status)
        .with_headers(headers)
        .fixed(response.body.as_bytes().to_vec()))
}
