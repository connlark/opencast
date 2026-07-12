use crate::route::{
    content_range_header, json_response as static_json_response, parse_range_header, route_request,
    unsatisfied_content_range_header, Header as StaticHeader, RangeError, RangeSelection,
    RouteAction, StaticResponse, JSON_CONTENT_TYPE, OBJECT_NOT_FOUND_JSON,
    RANGE_NOT_SATISFIABLE_JSON,
};
use worker::{console_error, Env, Headers, Method, Request, Response, Result};

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

pub async fn handle_request(req: Request, env: Env) -> Result<Response> {
    let method = req.method();
    let path = req.path();
    let config = GatewayConfig::from_env(&env)?;

    match route_request(
        method.as_ref(),
        &path,
        config.enabled,
        &config.object_prefix,
    ) {
        RouteAction::Static(response) => static_response(response),
        RouteAction::Manifest { object_key, head } => serve_manifest(&env, &object_key, head).await,
        RouteAction::ManifestSignature { object_key, head } => {
            serve_manifest(&env, &object_key, head).await
        }
        RouteAction::Asset { route, head } => {
            serve_asset(
                &env,
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

async fn serve_manifest(env: &Env, object_key: &str, head: bool) -> Result<Response> {
    let bucket = env.bucket(MODEL_BUCKET)?;
    let object = if head {
        bucket.head(object_key).await?
    } else {
        bucket.get(object_key).execute().await?
    };
    let Some(object) = object else {
        return json_error(404, OBJECT_NOT_FOUND_JSON);
    };

    let headers = object_headers(&object, JSON_CONTENT_TYPE, object.size(), None)?;
    if head {
        return Ok(Response::builder()
            .with_status(200)
            .with_headers(headers)
            .empty());
    }

    let Some(body) = object.body() else {
        return json_error(404, OBJECT_NOT_FOUND_JSON);
    };
    Ok(Response::builder()
        .with_status(200)
        .with_headers(headers)
        .body(body.response_body()?))
}

async fn serve_asset(
    env: &Env,
    req: &Request,
    method: Method,
    object_key: &str,
    content_type: &'static str,
    head: bool,
) -> Result<Response> {
    let bucket = env.bucket(MODEL_BUCKET)?;
    let range_header = req.headers().get("range")?;

    if range_header.is_some() || head {
        let Some(metadata) = bucket.head(object_key).await? else {
            return json_error(404, OBJECT_NOT_FOUND_JSON);
        };
        let size = metadata.size();
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
                    serve_full_asset(env, object_key, content_type).await
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

    serve_full_asset(env, object_key, content_type).await
}

async fn serve_full_asset(
    env: &Env,
    object_key: &str,
    content_type: &'static str,
) -> Result<Response> {
    let bucket = env.bucket(MODEL_BUCKET)?;
    let Some(object) = bucket.get(object_key).execute().await? else {
        return json_error(404, OBJECT_NOT_FOUND_JSON);
    };
    let headers = object_headers(&object, content_type, object.size(), None)?;
    let Some(body) = object.body() else {
        return json_error(404, OBJECT_NOT_FOUND_JSON);
    };
    Ok(Response::builder()
        .with_status(200)
        .with_headers(headers)
        .body(body.response_body()?))
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
