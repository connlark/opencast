//! Bounded publisher transport shared by queued observations and their tests.
use crate::deadline::fetch_with_deadline;
use crate::feed_fetch::{
    feed_response_disposition, same_origin, FeedFetchError, FeedResponseDisposition,
    FEED_USER_AGENT,
};
use crate::feed_stream::{FeedFetchCancellation, FeedStream};
use crate::{feed_admission, feed_resource, rss, storage};
use std::{cell::Cell, rc::Rc, time::Duration};
use worker::{Delay, Fetch, Headers, Method, Request, RequestInit, RequestRedirect};
const MAX_FEED_REDIRECTS: usize = 5;

pub(crate) struct FetchedFeed {
    pub(crate) parsed: std::result::Result<rss::scan::ScannedFeed, rss::RSSParseError>,
    pub(crate) etag: Option<String>,
    pub(crate) last_modified: Option<String>,
}

pub(crate) enum FeedFetchOutcome {
    NotModified,
    Fetched(Box<FetchedFeed>),
}

pub(crate) async fn fetch_feed(
    source_url: &str,
    etag: Option<&str>,
    last_modified: Option<&str>,
    feed: &storage::FeedSource,
    invocation_bytes: Rc<Cell<usize>>,
    observer: &mut crate::observation::runtime::ObserverSink,
) -> std::result::Result<FeedFetchOutcome, FeedFetchError> {
    let mut current_url = source_url.to_string();
    let original_url = url::Url::parse(source_url).map_err(|_| FeedFetchError::FetchFailed)?;

    for redirect_count in 0..=MAX_FEED_REDIRECTS {
        let parsed_current_url =
            url::Url::parse(&current_url).map_err(|_| FeedFetchError::FetchFailed)?;
        if let Some(origin) = observer.origin.as_mut() {
            observer.storage_pending = true;
            let admitted = origin.acquire(&parsed_current_url).await;
            observer.storage_pending = false;
            admitted?;
        }
        // From here a publisher request exists: only now can this scan's end
        // bound what a retry may first observe.
        observer.requesting();
        let headers = Headers::new();
        // UA-less fetches trip host WAFs into 403 -> six-hour backoff; one
        // unconditional identity serves both the poll and admission paths.
        headers
            .set("user-agent", FEED_USER_AGENT)
            .map_err(|_| FeedFetchError::FetchFailed)?;
        if same_origin(&parsed_current_url, &original_url) {
            if let Some(etag) = etag {
                headers
                    .set("if-none-match", etag)
                    .map_err(|_| FeedFetchError::FetchFailed)?;
            }
            if let Some(last_modified) = last_modified {
                headers
                    .set("if-modified-since", last_modified)
                    .map_err(|_| FeedFetchError::FetchFailed)?;
            }
        }

        let mut init = RequestInit::new();
        init.with_method(Method::Get)
            .with_headers(headers)
            .with_redirect(RequestRedirect::Manual);
        let request =
            Request::new_with_init(&current_url, &init).map_err(|_| FeedFetchError::FetchFailed)?;
        let cancellation = FeedFetchCancellation::default();
        let signal = cancellation.signal();
        let response = fetch_with_deadline(
            async {
                Fetch::Request(request)
                    .send_with_signal(&signal)
                    .await
                    .map_err(|_| FeedFetchError::FetchFailed)
            },
            Delay::from(Duration::from_secs(feed_resource::INACTIVITY_SECONDS)),
            FeedFetchError::FetchFailed,
        )
        .await?;
        let status = response.status_code();

        if let Some(origin) = observer.origin.as_mut() {
            observer.storage_pending = true;
            let recorded = origin.response(status, response.headers()).await;
            observer.storage_pending = false;
            recorded.map_err(|_| FeedFetchError::StorageFailed)?;
        }

        match feed_response_disposition(status) {
            FeedResponseDisposition::NotModified => {
                // A new or cross-origin request cannot validate a scan it
                // never completed. Keep admission failures visible in health.
                if !same_origin(&parsed_current_url, &original_url)
                    || (etag.is_none() && last_modified.is_none())
                {
                    return Err(FeedFetchError::UnexpectedNotModified);
                }
                return Ok(FeedFetchOutcome::NotModified);
            }
            FeedResponseDisposition::Redirect => {
                if redirect_count == MAX_FEED_REDIRECTS {
                    return Err(FeedFetchError::TooManyRedirects);
                }
                let location = response
                    .headers()
                    .get("location")
                    .map_err(|_| FeedFetchError::FetchFailed)?
                    .ok_or(FeedFetchError::MissingRedirectLocation)?;
                let next = parsed_current_url
                    .join(&location)
                    .map_err(|_| FeedFetchError::InvalidRedirect)?;
                feed_admission::admit_feed_url(next.as_str())
                    .map_err(|_| FeedFetchError::InvalidRedirect)?;
                current_url = next.to_string();
                continue;
            }
            FeedResponseDisposition::Other => {}
        }
        if !(200..300).contains(&status) {
            return Err(FeedFetchError::HTTPStatus(status));
        }

        let etag = response
            .headers()
            .get("etag")
            .map_err(|_| FeedFetchError::FetchFailed)?;
        let last_modified = response
            .headers()
            .get("last-modified")
            .map_err(|_| FeedFetchError::FetchFailed)?;
        let decoded_bytes = Rc::new(Cell::new(0usize));
        let stream = FeedStream::new(&response, invocation_bytes.clone(), decoded_bytes.clone())
            .map_err(|_| FeedFetchError::StorageFailed)?;
        let stream = if observer.origin.is_some() {
            stream.with_inactivity(crate::polling::policy::INACTIVITY_SECONDS)
        } else {
            stream
        };
        let parsed = rss::scan::scan_rss_with_sink(stream, &feed.feed_url, observer).await;

        return Ok(FeedFetchOutcome::Fetched(Box::new(FetchedFeed {
            parsed,
            etag,
            last_modified,
        })));
    }

    Err(FeedFetchError::TooManyRedirects)
}
