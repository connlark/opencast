#![cfg_attr(all(test, not(target_arch = "wasm32")), allow(dead_code))]

#[cfg(target_arch = "wasm32")]
use crate::database::slice_c::{self as identity, Operation};
use serde::Deserialize;
#[cfg(target_arch = "wasm32")]
use std::collections::BTreeMap;
#[cfg(target_arch = "wasm32")]
use worker::Result;

// Identity and retention operations share the storage interface.
#[cfg(target_arch = "wasm32")]
pub async fn prune_challenge_source_buckets_before(
    db: &crate::database::Authority,
    cutoff: i64,
) -> Result<()> {
    identity::decode(
        identity::execute(db, Operation::PruneChallengeSourceBuckets { cutoff }).await?,
    )
}

#[cfg(target_arch = "wasm32")]
pub async fn prune_challenges_before(db: &crate::database::Authority, cutoff: i64) -> Result<()> {
    identity::decode(identity::execute(db, Operation::PruneChallenges { cutoff }).await?)
}

#[derive(Debug, Deserialize)]
pub struct DeviceRow {
    pub device_token: String,
    pub device_token_hash: String,
}

#[derive(Debug, Deserialize)]
pub struct FeedSummaryRow {
    pub feed_url: String,
    pub title: Option<String>,
    #[serde(default)]
    pub consecutive_failures: i64,
    pub last_http_status: Option<i64>,
    pub last_error: Option<String>,
    pub last_polled_at: Option<i64>,
}

#[derive(Debug, Deserialize)]
pub struct FeedSource {
    pub feed_url: String,
    pub source_url: String,
    pub etag: Option<String>,
    pub last_modified: Option<String>,
    /// The hop whose parsed 200 supplied the validators, and when.
    pub validator_url: Option<String>,
    pub validator_at: Option<i64>,
}

#[derive(Debug, Deserialize)]
pub struct InstallSubscriptionRow {
    pub feed_url: String,
}

pub struct DeviceUpsert<'a> {
    pub install_id: &'a str,
    pub key_id: &'a str,
    pub device_token: &'a str,
    pub device_token_hash: &'a str,
    pub apns_environment: &'a str,
    pub bundle_id: &'a str,
    pub notifications_enabled: bool,
    pub job_capable: bool,
    pub now: i64,
}

pub struct PushSendAttemptInsert<'a> {
    pub attempt_id: &'a str,
    pub install_id: Option<&'a str>,
    pub device_token_hash: Option<&'a str>,
    pub apns_environment: &'a str,
    pub apns_status: Option<i32>,
    pub apns_id: Option<&'a str>,
    pub apns_error: Option<&'a str>,
    pub created_at: i64,
}

pub struct FeedAdmissionAttemptInsert<'a> {
    pub attempt_id: &'a str,
    pub install_id: &'a str,
    pub key_id: &'a str,
    pub host: Option<&'a str>,
    pub accepted: bool,
    pub error_code: Option<&'a str>,
    pub created_at: i64,
}

#[cfg(target_arch = "wasm32")]
pub async fn insert_secure_attempt(
    db: &crate::database::Authority,
    attempt_id: &str,
    install_id: Option<&str>,
    key_id: Option<&str>,
    accepted: bool,
    error_code: Option<&str>,
    created_at: i64,
) -> Result<()> {
    identity::decode(
        identity::execute(
            db,
            Operation::SecureAttempt {
                id: attempt_id.into(),
                install: install_id.map(str::to_owned),
                key: key_id.map(str::to_owned),
                accepted,
                error: error_code.map(str::to_owned),
                now: created_at,
            },
        )
        .await?,
    )
}

#[cfg(target_arch = "wasm32")]
pub async fn prune_secure_attempts_before(
    db: &crate::database::Authority,
    cutoff: i64,
) -> Result<usize> {
    identity::decode(identity::execute(db, Operation::PruneSecureAttempts { cutoff }).await?)
}

#[cfg(target_arch = "wasm32")]
pub async fn upsert_device(
    db: &crate::database::Authority,
    device: DeviceUpsert<'_>,
) -> Result<()> {
    identity::decode(
        identity::execute(
            db,
            Operation::RegisterDevice {
                device: identity::Device {
                    install: device.install_id.into(),
                    key: device.key_id.into(),
                    token: device.device_token.into(),
                    token_hash: device.device_token_hash.into(),
                    environment: device.apns_environment.into(),
                    bundle: device.bundle_id.into(),
                    enabled: device.notifications_enabled,
                    job_capable: device.job_capable,
                    now: device.now,
                },
            },
        )
        .await?,
    )
}

#[cfg(target_arch = "wasm32")]
pub async fn disable_device(
    db: &crate::database::Authority,
    install_id: &str,
    device_token_hash: &str,
    now: i64,
) -> Result<()> {
    identity::decode(
        identity::execute(
            db,
            Operation::DisableDevice {
                install: install_id.into(),
                token_hash: device_token_hash.into(),
                now,
            },
        )
        .await?,
    )
}

#[cfg(target_arch = "wasm32")]
pub async fn device_exists(
    db: &crate::database::Authority,
    install_id: &str,
    device_token_hash: &str,
) -> Result<bool> {
    identity::decode(
        identity::execute(
            db,
            Operation::DeviceExists {
                install: install_id.into(),
                token_hash: device_token_hash.into(),
            },
        )
        .await?,
    )
}

#[cfg(target_arch = "wasm32")]
pub async fn enabled_device_count_for_install(
    db: &crate::database::Authority,
    install_id: &str,
    apns_environment: &str,
    bundle_id: &str,
) -> Result<i64> {
    identity::decode(
        identity::execute(
            db,
            Operation::CountEnabledDevices {
                install: install_id.into(),
                environment: apns_environment.into(),
                bundle: bundle_id.into(),
            },
        )
        .await?,
    )
}

#[cfg(target_arch = "wasm32")]
pub async fn latest_enabled_device(
    db: &crate::database::Authority,
    install_id: &str,
    apns_environment: &str,
) -> Result<Option<DeviceRow>> {
    identity::decode(
        identity::execute(
            db,
            Operation::LatestDevice {
                install: install_id.into(),
                environment: apns_environment.into(),
            },
        )
        .await?,
    )
}

#[cfg(target_arch = "wasm32")]
pub async fn registration_ready(
    db: &crate::database::Authority,
    install_id: &str,
    apns_environment: &str,
    bundle_id: &str,
) -> Result<bool> {
    identity::decode(
        identity::execute(
            db,
            Operation::RegistrationReady {
                install: install_id.into(),
                environment: apns_environment.into(),
                bundle: bundle_id.into(),
            },
        )
        .await?,
    )
}

#[cfg(target_arch = "wasm32")]
pub async fn insert_push_send_attempt(
    db: &crate::database::Authority,
    attempt: PushSendAttemptInsert<'_>,
) -> Result<()> {
    identity::decode(
        identity::execute(
            db,
            Operation::PushAttempt {
                id: attempt.attempt_id.into(),
                install: attempt.install_id.map(str::to_owned),
                token_hash: attempt.device_token_hash.map(str::to_owned),
                environment: attempt.apns_environment.into(),
                status: attempt.apns_status,
                apns_id: attempt.apns_id.map(str::to_owned),
                error: attempt.apns_error.map(str::to_owned),
                now: attempt.created_at,
            },
        )
        .await?,
    )
}

/// Resolves the known feeds among `feed_urls` in one statement over the
/// whole URL array instead of one query per feed. Unknown URLs are
/// simply absent from the map.
#[cfg(target_arch = "wasm32")]
pub async fn feed_summaries(
    db: &crate::database::Authority,
    feed_urls: &[&str],
) -> Result<BTreeMap<String, FeedSummaryRow>> {
    identity::decode(
        identity::execute(
            db,
            Operation::FeedSummaries {
                urls: feed_urls.iter().map(|v| (*v).to_owned()).collect(),
            },
        )
        .await?,
    )
}

#[cfg(target_arch = "wasm32")]
pub async fn accepted_admission_count_since(
    db: &crate::database::Authority,
    install_id: &str,
    since: i64,
) -> Result<i64> {
    identity::decode(
        identity::execute(
            db,
            Operation::CountAdmissions {
                install: install_id.into(),
                since,
            },
        )
        .await?,
    )
}

/// Accepted-admission counts since `since`, grouped per host, in IN-list
/// chunks. Hosts without an accepted attempt in the window are absent.
#[cfg(target_arch = "wasm32")]
pub async fn accepted_admission_counts_for_hosts_since(
    db: &crate::database::Authority,
    hosts: &[&str],
    since: i64,
) -> Result<BTreeMap<String, i64>> {
    identity::decode(
        identity::execute(
            db,
            Operation::CountHostAdmissions {
                hosts: hosts.iter().map(|v| (*v).to_owned()).collect(),
                since,
            },
        )
        .await?,
    )
}

#[cfg(target_arch = "wasm32")]
pub async fn global_accepted_admission_count_since(
    db: &crate::database::Authority,
    since: i64,
) -> Result<i64> {
    identity::decode(identity::execute(db, Operation::CountGlobalAdmissions { since }).await?)
}

/// Records admission in the catalog; the feed's current authority schedules
/// its quiet first baseline. Racing inserts preserve the first source URL.
#[cfg(target_arch = "wasm32")]
pub fn insert_pending_feed_statement(
    _db: &crate::database::Authority,
    feed_url: &str,
    source_url: &str,
    now: i64,
) -> Result<identity::SubscriptionWrite> {
    Ok(identity::SubscriptionWrite::PendingFeed {
        url: feed_url.into(),
        source: source_url.into(),
        now,
    })
}

/// Runs the subscription-sync write set as one storage transaction; an empty
/// set is a no-op.
#[cfg(target_arch = "wasm32")]
pub async fn run_write_batch(
    db: &crate::database::Authority,
    statements: Vec<identity::SubscriptionWrite>,
) -> Result<()> {
    identity::decode(
        identity::execute(db, Operation::SyncSubscriptions { writes: statements }).await?,
    )
}

#[cfg(target_arch = "wasm32")]
pub fn upsert_feed_subscription_statement(
    _db: &crate::database::Authority,
    install_id: &str,
    feed_url: &str,
    notifications_enabled: bool,
    now: i64,
    key_id: &str,
) -> Result<identity::SubscriptionWrite> {
    Ok(identity::SubscriptionWrite::Upsert {
        install: install_id.into(),
        key: key_id.into(),
        url: feed_url.into(),
        enabled: notifications_enabled,
        now,
    })
}

#[cfg(target_arch = "wasm32")]
pub async fn install_subscription_feed_urls(
    db: &crate::database::Authority,
    install_id: &str,
) -> Result<Vec<InstallSubscriptionRow>> {
    identity::decode(
        identity::execute(
            db,
            Operation::ReadSubscriptions {
                install: install_id.into(),
            },
        )
        .await?,
    )
}

#[cfg(target_arch = "wasm32")]
pub fn mark_subscription_deleted_statement(
    _db: &crate::database::Authority,
    install_id: &str,
    feed_url: &str,
    now: i64,
    key_id: &str,
) -> Result<identity::SubscriptionWrite> {
    Ok(identity::SubscriptionWrite::MarkDeleted {
        install: install_id.into(),
        key: key_id.into(),
        url: feed_url.into(),
        now,
    })
}

#[cfg(target_arch = "wasm32")]
pub async fn delete_install_data(
    db: &crate::database::Authority,
    install_id: &str,
    fence: &str,
    now: i64,
) -> Result<()> {
    identity::decode(
        identity::execute(
            db,
            Operation::EraseInstall {
                install: install_id.into(),
                fence: fence.into(),
                now,
            },
        )
        .await?,
    )
}

// Deletion removes the old challenge; fresh enrollment under the same install
// remains allowed, but a pre-deletion attestation continuation cannot restore it.
#[allow(clippy::too_many_arguments)]
#[cfg(target_arch = "wasm32")]
pub async fn upsert_key_for_challenge(
    db: &crate::database::Authority,
    install_id: &str,
    key_id: &str,
    public_key: &[u8],
    app_id: &str,
    environment: &str,
    now: i64,
    challenge_id: &str,
) -> Result<bool> {
    identity::decode(
        identity::execute(
            db,
            Operation::RegisterKey {
                install: install_id.into(),
                key: key_id.into(),
                public_key: public_key.to_vec(),
                app_id: app_id.into(),
                environment: environment.into(),
                now,
                challenge: challenge_id.into(),
            },
        )
        .await?,
    )
}

#[cfg(target_arch = "wasm32")]
pub fn insert_feed_admission_attempt_statement(
    _db: &crate::database::Authority,
    attempt: FeedAdmissionAttemptInsert<'_>,
) -> Result<identity::SubscriptionWrite> {
    Ok(identity::SubscriptionWrite::Attempt {
        attempt: identity::AdmissionAttempt {
            id: attempt.attempt_id.into(),
            install: attempt.install_id.into(),
            key: attempt.key_id.into(),
            host: attempt.host.map(str::to_owned),
            accepted: attempt.accepted,
            error: attempt.error_code.map(str::to_owned),
            now: attempt.created_at,
        },
    })
}

#[cfg(target_arch = "wasm32")]
pub async fn prune_feed_admission_attempts_before(
    db: &crate::database::Authority,
    cutoff: i64,
) -> Result<usize> {
    identity::decode(identity::execute(db, Operation::PruneAdmissionAttempts { cutoff }).await?)
}

#[cfg(target_arch = "wasm32")]
pub async fn prune_push_send_attempts_before(
    db: &crate::database::Authority,
    cutoff: i64,
) -> Result<usize> {
    identity::decode(identity::execute(db, Operation::PrunePushAttempts { cutoff }).await?)
}

/// Hard-deletes subscription rows soft-deleted before `cutoff`. Resubscribing
/// after the GC is free: the feed row survives (only zero-subscriber feeds
/// age out separately), so sync re-accepts without a new-feed admission.
#[cfg(target_arch = "wasm32")]
pub async fn gc_deleted_subscriptions_before(
    db: &crate::database::Authority,
    cutoff: i64,
) -> Result<usize> {
    identity::decode(identity::execute(db, Operation::GcDeletedSubscriptions { cutoff }).await?)
}

/// Resolves the installed client's source URL; queued validators live in n_feed.
#[cfg(target_arch = "wasm32")]
pub async fn feed_source(
    db: &crate::database::Authority,
    feed_url: &str,
) -> Result<Option<FeedSource>> {
    let row = crate::database::execute(
        db,
        crate::database::polling::Operation::ReadFeedSource {
            url: feed_url.into(),
        },
    )
    .await?
    .first();
    row.map(serde_json::from_value)
        .transpose()
        .map_err(Into::into)
}

#[cfg(target_arch = "wasm32")]
#[allow(clippy::too_many_arguments)]
pub async fn insert_challenge_within_limits(
    db: &crate::database::Authority,
    challenge_id: &str,
    challenge: &str,
    purpose: &str,
    install_id: &str,
    created_at: i64,
    expires_at: i64,
    window_start: i64,
) -> Result<bool> {
    identity::decode(
        identity::execute(
            db,
            Operation::IssueChallenge {
                id: challenge_id.into(),
                challenge: challenge.into(),
                purpose: purpose.into(),
                install: install_id.into(),
                created: created_at,
                expires: expires_at,
                window_start,
            },
        )
        .await?,
    )
}

#[cfg(target_arch = "wasm32")]
pub async fn challenge(
    db: &crate::database::Authority,
    challenge_id: &str,
) -> Result<Option<opencast_app_attest_core::app_attest_storage::ChallengeRow>> {
    identity::decode(
        identity::execute(
            db,
            Operation::ReadChallenge {
                id: challenge_id.into(),
            },
        )
        .await?,
    )
}

#[cfg(target_arch = "wasm32")]
pub async fn increment_challenge_source_bucket(
    db: &crate::database::Authority,
    source_token: &str,
    window_start: i64,
    now: i64,
) -> Result<i64> {
    identity::decode(
        identity::execute(
            db,
            Operation::IncrementSource {
                source: source_token.into(),
                window_start,
                now,
            },
        )
        .await?,
    )
}

#[cfg(target_arch = "wasm32")]
pub async fn key(
    db: &crate::database::Authority,
    install_id: &str,
    key_id: &str,
) -> Result<Option<opencast_app_attest_core::app_attest_storage::AppAttestKeyRow>> {
    identity::decode(
        identity::execute(
            db,
            Operation::ReadKey {
                install: install_id.into(),
                key: key_id.into(),
            },
        )
        .await?,
    )
}

#[cfg(target_arch = "wasm32")]
pub async fn app_attest_key_count_since(
    db: &crate::database::Authority,
    install_id: &str,
    since: i64,
) -> Result<i64> {
    identity::decode(
        identity::execute(
            db,
            Operation::CountKeys {
                install: install_id.into(),
                since,
            },
        )
        .await?,
    )
}

#[cfg(target_arch = "wasm32")]
pub async fn mark_challenge_consumed(
    db: &crate::database::Authority,
    challenge_id: &str,
    consumed_at: i64,
) -> Result<bool> {
    identity::decode(
        identity::execute(
            db,
            Operation::ConsumeChallenge {
                id: challenge_id.into(),
                now: consumed_at,
            },
        )
        .await?,
    )
}
