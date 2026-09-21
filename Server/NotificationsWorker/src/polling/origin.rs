//! Queue-local publisher safety. An isolate admits one request per origin,
//! redirect destinations included; consumer concurrency bounds the fleet. No D1
//! row is held across network I/O. `n_poll_origin` is publisher backoff schedule
//! state only: written when an origin fails or recovers, never by a healthy poll.
use super::{policy, Fence};
use crate::{
    delivery::{
        db::*,
        wire::{hash, int},
    },
    feed_fetch::FeedFetchError,
};
use serde_json::json;
use std::{cell::RefCell, collections::HashMap};
use worker::{D1Database, Headers, Result};

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
    db: D1Database,
    fence: Fence,
    current: Option<Guard>,
    /// Backoff state of the origin being fetched, read before its request.
    failures: i64,
    /// Set when a deferral should wait for a publisher cooldown.
    pub cooldown_until: Option<i64>,
}
impl Session {
    pub fn new(db: D1Database, fence: Fence) -> Self {
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
        let state = first(&self.db,&format!("SELECT COALESCE((SELECT cooldown_until FROM n_poll_origin WHERE origin_key=?1),0) AS cooldown_until,COALESCE((SELECT failures FROM n_poll_origin WHERE origin_key=?1),0) AS failures WHERE {}",self.fence.sql(t)),&[json!(key)]).await.map_err(|_| FeedFetchError::StorageFailed)?;
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
                super::stat(&self.db, "retry_after_clamps").await?;
            }
            run(&self.db,&format!("INSERT INTO n_poll_origin(origin_key,cooldown_until,failures,last_status,updated_at) SELECT ?1,?2,1,?3,?4 WHERE {} ON CONFLICT(origin_key) DO UPDATE SET cooldown_until=MAX(cooldown_until,excluded.cooldown_until),failures=MIN(failures+1,12),last_status=excluded.last_status,updated_at=excluded.updated_at",self.fence.sql(t)),&[json!(key),json!(until),json!(status),json!(t)]).await?;
            self.cooldown_until = Some(until);
        } else if (200..400).contains(&status) && self.failures > 0 {
            run(&self.db,&format!("UPDATE n_poll_origin SET failures=0,last_status=?2,updated_at=?3 WHERE origin_key=?1 AND failures>0 AND {}",self.fence.sql(t)),&[json!(key),json!(status),json!(t)]).await?;
            self.failures = 0;
        }
        Ok(())
    }
}
