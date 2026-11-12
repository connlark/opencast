//! Queue-local publisher safety. An isolate admits one request per origin,
//! redirect destinations included; consumer concurrency bounds the fleet. No database
//! row is held across network I/O. `n_poll_origin` is publisher backoff schedule
//! state only: written when an origin fails or recovers, never by a healthy poll.
//! The origin slot belongs to the scan permit that took it and dies with it
//! (`feed_scan_admission::OriginSlot`): a cancelled invocation that never drops
//! its guard leaves a dead slot the permit's reclaims and the next entry remove.
use super::{policy, Fence};
use crate::database::{self, polling::Operation};
use crate::{
    delivery::{
        db::*,
        wire::{hash, int},
    },
    feed_fetch::FeedFetchError,
    feed_scan_admission::OriginSlot,
};
use serde_json::json;
use worker::{Headers, Result};

pub fn key(url: &url::Url) -> String {
    hash(&["origin-v1", &url.origin().ascii_serialization()])
}

pub struct Session {
    db: crate::database::Authority,
    fence: Fence,
    /// The scan permit owner whose origin slots this session takes.
    owner: u64,
    current: Option<OriginSlot>,
    /// Backoff state of the origin being fetched, read before its request.
    failures: i64,
    /// Set when a deferral should wait for a publisher cooldown.
    pub cooldown_until: Option<i64>,
}
impl Session {
    /// `owner` is the first permit of the scan's acquisition, which stays
    /// intact until this session's guards are disposed.
    pub fn new(db: crate::database::Authority, fence: Fence, owner: u64) -> Self {
        Self {
            db,
            fence,
            owner,
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
        let guard = match OriginSlot::hop(self.current.take(), &key, self.owner) {
            Ok(guard) => guard,
            Err(refused) => {
                worker::console_log!(
                    "{}",
                    json!({"event":"poll_outcome","outcome":"origin_deferred","reason":"consumer_busy","cause":refused.cause,"holder_slot_age_seconds":refused.holder_slot_age_seconds,"isolate":refused.isolate})
                );
                return Err(FeedFetchError::OriginDeferred);
            }
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
        let Some(key) = self
            .current
            .as_ref()
            .map(|guard| guard.origin().to_string())
        else {
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
