//! Queue-local publisher safety. An isolate admits one request per origin,
//! redirect destinations included; consumer concurrency bounds the fleet. No database
//! row is held across network I/O. `n_poll_origin` is publisher backoff schedule
//! state only: written when an origin fails or recovers, never by a healthy poll.
use super::{policy, Fence};
use crate::database::{self, polling::Operation};
use crate::{
    delivery::{
        db::*,
        wire::{hash, int},
    },
    feed_fetch::FeedFetchError,
};
use serde_json::json;
use std::{cell::RefCell, collections::HashMap};
use worker::{Headers, Result};

thread_local! {
    // Scalar occupancy only: never request I/O, buffers or futures.
    static ACTIVE: RefCell<HashMap<String, usize>> = RefCell::new(HashMap::new());
}
/// Dropping the scan, including cancellation, frees the origin.
struct Guard(String);
impl Guard {
    fn enter(key: &str) -> Option<Self> {
        ACTIVE.with(|active| {
            let mut active = active.borrow_mut();
            let count = active.entry(key.into()).or_insert(0);
            if *count >= policy::ORIGIN_LIMIT_PER_CONSUMER {
                return None;
            }
            *count += 1;
            Some(Self(key.into()))
        })
    }
}
impl Drop for Guard {
    fn drop(&mut self) {
        ACTIVE.with(|active| {
            let mut active = active.borrow_mut();
            if let Some(count) = active.get_mut(&self.0) {
                *count = count.saturating_sub(1);
                if *count == 0 {
                    active.remove(&self.0);
                }
            }
        });
    }
}
pub fn key(url: &url::Url) -> String {
    hash(&["origin-v1", &url.origin().ascii_serialization()])
}

pub struct Session {
    db: crate::database::Authority,
    fence: Fence,
    current: Option<Guard>,
    /// Backoff state of the origin being fetched, read before its request.
    failures: i64,
    /// Set when a deferral should wait for a publisher cooldown.
    pub cooldown_until: Option<i64>,
}
impl Session {
    pub fn new(db: crate::database::Authority, fence: Fence) -> Self {
        Self {
            db,
            fence,
            current: None,
            failures: 0,
            cooldown_until: None,
        }
    }
    pub async fn acquire(&mut self, url: &url::Url) -> std::result::Result<(), FeedFetchError> {
        crate::feed_admission::admit_feed_url(url.as_str())
            .map_err(|_| FeedFetchError::InvalidRedirect)?;
        let key = key(url);
        // A redirect within the origin keeps its slot; one to another origin
        // gives up the previous slot first. Every hop rechecks the fence.
        let guard = match self.current.take() {
            Some(guard) if guard.0 == key => Some(guard),
            previous => {
                drop(previous);
                Guard::enter(&key)
            }
        };
        let Some(guard) = guard else {
            worker::console_log!(
                "{}",
                json!({"event":"poll_outcome","outcome":"origin_deferred","reason":"consumer_busy"})
            );
            return Err(FeedFetchError::OriginDeferred);
        };
        // One read, immediately before the request, covers the cooldown and
        // the message fence, so a revoked generation cannot follow another hop.
        // The source origin is read here too: a copy taken with the message
        // claim misses a cooldown committed while this scan waited for its
        // permit or its origin slot.
        let t = now();
        let state = database::execute(
            &self.db,
            Operation::ReadOrigin {
                fence: self.fence.storage(),
                origin: key.clone(),
                now: t,
            },
        )
        .await
        .map_err(|_| FeedFetchError::StorageFailed)?
        .first();
        let Some(state) = state else {
            return Err(FeedFetchError::OriginDeferred);
        };
        if int(&state, "cooldown_until") > t {
            self.cooldown_until = Some(int(&state, "cooldown_until"));
            worker::console_log!(
                "{}",
                json!({"event":"poll_outcome","outcome":"origin_deferred","reason":"publisher_cooldown"})
            );
            return Err(FeedFetchError::OriginDeferred);
        }
        self.failures = int(&state, "failures");
        self.current = Some(guard);
        Ok(())
    }
    pub async fn response(&mut self, status: u16, headers: &Headers) -> Result<()> {
        let Some(key) = self.current.as_ref().map(|guard| guard.0.clone()) else {
            return Ok(());
        };
        let t = now();
        if status == 429 || status >= 500 {
            let delay = policy::retry_delay(self.failures);
            let until = headers
                .get("retry-after")?
                .as_deref()
                .and_then(|v| policy::retry_after(v, t))
                .unwrap_or(t + delay)
                .max(t + delay);
            let clamped = until > t.saturating_add(policy::RETRY_AFTER_MAX_SECONDS);
            let until = until.min(t.saturating_add(policy::RETRY_AFTER_MAX_SECONDS));
            if clamped {
                worker::console_warn!(
                    "{}",
                    json!({"event":"retry_after_clamped","ceiling_seconds":policy::RETRY_AFTER_MAX_SECONDS})
                );
                super::stat(
                    &self.db,
                    crate::database::polling::Counter::RetryAfterClamps,
                )
                .await?;
            }
            database::execute(
                &self.db,
                Operation::RecordOriginFailure {
                    fence: self.fence.storage(),
                    origin: key,
                    until,
                    status: status.into(),
                    now: t,
                },
            )
            .await?;
            self.cooldown_until = Some(until);
        } else if (200..400).contains(&status) && self.failures > 0 {
            database::execute(
                &self.db,
                Operation::RecordOriginRecovery {
                    fence: self.fence.storage(),
                    origin: key,
                    status: status.into(),
                    now: t,
                },
            )
            .await?;
            self.failures = 0;
        }
        Ok(())
    }
}
