//! Independent, read-only polling health check on Notifications' minute cron.
use super::{dispatch, policy};
use crate::{
    deadline::fetch_with_deadline,
    delivery::db::{first, lane, now},
};
use serde_json::json;
use std::time::Duration;
use worker::*;

pub(crate) async fn check(env: &Env, scheduled_at: i64) {
    // Use the scheduled minute, not invocation arrival time: delayed cron
    // delivery must not skip a five-minute check or create extra checks.
    if scheduled_at.div_euclid(60).rem_euclid(5) != 0 {
        return;
    }
    let Some(target) = dispatch::alert_target(env) else {
        return;
    };
    let t = now();
    let read = async {
        let db = env.d1("APP_ATTEST_DB")?;
        let row = first(&db, &format!(
            "SELECT (SELECT COUNT(*) FROM n_feed f WHERE {}) AS late_900, (SELECT stall_state FROM n_poll_dispatch WHERE id=1) AS stall_state",
            dispatch::late_scanned(900)
        ), &[json!(t)]).await?.ok_or_else(|| Error::RustError("watchdog_missing_health".into()))?;
        let late = row["late_900"]
            .as_i64()
            .ok_or_else(|| Error::RustError("watchdog_invalid_count".into()))?;
        let state = row["stall_state"]
            .as_str()
            .filter(|s| matches!(*s, "clear" | "stalled"))
            .ok_or_else(|| Error::RustError("watchdog_invalid_stall_state".into()))?;
        Ok::<_, Error>((late, state == "clear"))
    };
    let health = fetch_with_deadline(
        read,
        Delay::from(Duration::from_secs(10)),
        Error::RustError("watchdog_read_timeout".into()),
    )
    .await;
    let late = match health {
        Ok((late, clear)) => {
            console_log!(
                "{}",
                json!({"event":"poll_watchdog","late_900":late,"dispatcher_clear":clear,"read":"ok"})
            );
            if late < policy::LATE_FEED_THRESHOLD || !clear {
                return;
            }
            Some(late)
        }
        Err(error) => {
            console_warn!(
                "{}",
                json!({"event":"poll_watchdog","read":"failed","reason":error.to_string()})
            );
            None
        }
    };
    let lane = lane(env);
    // Both failure modes share the bucket: changing health within the bucket
    // cannot produce an additional page. The webhook owns deduplication.
    let draft = dispatch::AlertDraft::Watchdog {
        lane: &lane,
        bucket: t.div_euclid(1800),
        late,
    };
    // Include the response body in this deadline as well as the request.
    let sent = fetch_with_deadline(
        dispatch::send_alert(&target, draft),
        Delay::from(Duration::from_secs(10)),
        Error::RustError("watchdog_alert_timeout".into()),
    )
    .await;
    console_log!(
        "{}",
        json!({"event":"poll_watchdog_alert","delivered":matches!(sent, Ok(true))})
    );
    // Best effort, no persistent state, and no error escapes to maintenance.
}
