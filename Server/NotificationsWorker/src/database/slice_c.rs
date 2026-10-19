//! Closed identity requests; callers provide domain values, never SQL or clients.
use super::{Failure, Kind, Metrics, Outcome, Parameter, Phase};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Device {
    pub install: String,
    pub key: String,
    pub token: String,
    pub token_hash: String,
    pub environment: String,
    pub bundle: String,
    pub enabled: bool,
    pub job_capable: bool,
    pub now: i64,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AdmissionAttempt {
    pub id: String,
    pub install: String,
    pub key: String,
    pub host: Option<String>,
    pub accepted: bool,
    pub error: Option<String>,
    pub now: i64,
}
/// The source-ordered, preselected batch. Quota and stale-set reads remain
/// outside this operation. PostgreSQL collapses these five families only.
#[derive(Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum SubscriptionWrite {
    EnsureFeed {
        url: String,
        now: i64,
    },
    PendingFeed {
        url: String,
        source: String,
        now: i64,
    },
    Attempt {
        attempt: AdmissionAttempt,
    },
    Upsert {
        install: String,
        key: String,
        url: String,
        enabled: bool,
        now: i64,
    },
    MarkDeleted {
        install: String,
        key: String,
        url: String,
        now: i64,
    },
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
pub enum Operation {
    PruneChallengeSourceBuckets {
        cutoff: i64,
    },
    PruneChallenges {
        cutoff: i64,
    },
    PrunePushAttempts {
        cutoff: i64,
    },
    GcDeletedSubscriptions {
        cutoff: i64,
    },
    PruneSecureAttempts {
        cutoff: i64,
    },
    PruneAdmissionAttempts {
        cutoff: i64,
    },

    IssueChallenge {
        id: String,
        challenge: String,
        purpose: String,
        install: String,
        created: i64,
        expires: i64,
        window_start: i64,
    },
    ReadChallenge {
        id: String,
    },
    IncrementSource {
        source: String,
        window_start: i64,
        now: i64,
    },
    DeleteIdentity {
        install: String,
    },
    ConsumeChallenge {
        id: String,
        now: i64,
    },
    ReadKey {
        install: String,
        key: String,
    },
    CountKeys {
        install: String,
        since: i64,
    },
    AdvanceCounter {
        install: String,
        key: String,
        previous: i64,
        next: i64,
        now: i64,
    },
    RegisterKey {
        install: String,
        key: String,
        public_key: Vec<u8>,
        app_id: String,
        environment: String,
        now: i64,
        challenge: String,
    },
    RegisterDevice {
        device: Device,
    },
    DisableDevice {
        install: String,
        token_hash: String,
        now: i64,
    },
    DeviceExists {
        install: String,
        token_hash: String,
    },
    CountEnabledDevices {
        install: String,
        environment: String,
        bundle: String,
    },
    LatestDevice {
        install: String,
        environment: String,
    },
    RegistrationReady {
        install: String,
        environment: String,
        bundle: String,
    },
    SecureAttempt {
        id: String,
        install: Option<String>,
        key: Option<String>,
        accepted: bool,
        error: Option<String>,
        now: i64,
    },
    PushAttempt {
        id: String,
        install: Option<String>,
        token_hash: Option<String>,
        environment: String,
        status: Option<i32>,
        apns_id: Option<String>,
        error: Option<String>,
        now: i64,
    },
    FeedSummaries {
        urls: Vec<String>,
    },
    CountAdmissions {
        install: String,
        since: i64,
    },
    CountHostAdmissions {
        hosts: Vec<String>,
        since: i64,
    },
    CountGlobalAdmissions {
        since: i64,
    },
    ReadSubscriptions {
        install: String,
    },
    SyncSubscriptions {
        writes: Vec<SubscriptionWrite>,
    },
    EraseInstall {
        install: String,
        fence: String,
        now: i64,
    },
}
impl Operation {
    pub fn is_read(&self) -> bool {
        matches!(
            self,
            Self::ReadChallenge { .. }
                | Self::ReadKey { .. }
                | Self::CountKeys { .. }
                | Self::DeviceExists { .. }
                | Self::CountEnabledDevices { .. }
                | Self::LatestDevice { .. }
                | Self::RegistrationReady { .. }
                | Self::FeedSummaries { .. }
                | Self::CountAdmissions { .. }
                | Self::CountHostAdmissions { .. }
                | Self::CountGlobalAdmissions { .. }
                | Self::ReadSubscriptions { .. }
        )
    }
    pub fn id(&self) -> &'static str {
        use Operation::*;
        match self {
            PruneChallengeSourceBuckets { .. } => "prune_challenge_source_buckets",
            PruneChallenges { .. } => "prune_challenges",
            PrunePushAttempts { .. } => "prune_push_attempts",
            GcDeletedSubscriptions { .. } => "gc_deleted_subscriptions",
            PruneSecureAttempts { .. } => "prune_secure_attempts",
            PruneAdmissionAttempts { .. } => "prune_admission_attempts",
            IssueChallenge { .. } => "issue_challenge",
            ReadChallenge { .. } => "read_challenge",
            IncrementSource { .. } => "increment_source",
            DeleteIdentity { .. } => "B01",
            ConsumeChallenge { .. } => "consume_challenge",
            ReadKey { .. } => "read_key",
            CountKeys { .. } => "count_keys",
            AdvanceCounter { .. } => "advance_counter",
            RegisterKey { .. } => "register_key",
            RegisterDevice { .. } => "B18",
            DisableDevice { .. } => "disable_device",
            DeviceExists { .. } => "device_exists",
            CountEnabledDevices { .. } => "count_enabled_devices",
            LatestDevice { .. } => "latest_device",
            RegistrationReady { .. } => "registration_ready",
            SecureAttempt { .. } => "secure_attempt",
            PushAttempt { .. } => "push_attempt",
            FeedSummaries { .. } => "feed_summaries",
            CountAdmissions { .. } => "count_admissions",
            CountHostAdmissions { .. } => "count_host_admissions",
            CountGlobalAdmissions { .. } => "count_global_admissions",
            ReadSubscriptions { .. } => "read_subscriptions",
            SyncSubscriptions { .. } => "B19",
            EraseInstall { .. } => "B20",
        }
    }
}
/// The exact source helper result. Unit writes return null; exact-one writes
/// return bool.
#[derive(Serialize)]
pub struct Response {
    pub value: Value,
    pub metrics: Metrics,
    /// PostgreSQL command counts are transport evidence, not helper return
    /// values; unit writes discard them.
    pub physical_counts: Option<Vec<u64>>,
}
pub(super) fn validate(operation: &Operation) -> super::Result<()> {
    fn valid(value: &Value) -> bool {
        match value {
            Value::Number(n) => n
                .as_i64()
                .is_some_and(|n| Parameter::Integer(Some(n)).validate().is_ok()),
            Value::Array(a) => a.iter().all(valid),
            Value::Object(o) => o.values().all(valid),
            _ => true,
        }
    }
    let expiry_valid = !matches!(operation, Operation::EraseInstall { now, .. }
        if now.checked_add(604800).is_none_or(|n| Parameter::Integer(Some(n)).validate().is_err()));
    // The native sync caller selects one install/key/time and deduplicates its
    // canonical URLs before building the five families. Keep that same domain;
    // do not let an impossible repeated upsert change PostgreSQL conflict rules.
    let mut selection_valid = true;
    if let Operation::SyncSubscriptions { writes } = operation {
        let mut timestamp = None;
        let mut identity = None;
        let mut selected = std::collections::BTreeSet::new();
        for write in writes {
            let (family, url, who, now) = match write {
                SubscriptionWrite::EnsureFeed { url, now } => (0, Some(url), None, *now),
                SubscriptionWrite::PendingFeed { url, now, .. } => (1, Some(url), None, *now),
                SubscriptionWrite::Attempt { attempt } => {
                    (2, None, Some((&attempt.install, &attempt.key)), attempt.now)
                }
                SubscriptionWrite::Upsert {
                    install,
                    key,
                    url,
                    now,
                    ..
                } => (3, Some(url), Some((install, key)), *now),
                SubscriptionWrite::MarkDeleted {
                    install,
                    key,
                    url,
                    now,
                } => (4, Some(url), Some((install, key)), *now),
            };
            if timestamp.replace(now).is_some_and(|old| old != now) {
                selection_valid = false;
            }
            if let Some(who) = who {
                if identity.replace(who).is_some_and(|old| old != who) {
                    selection_valid = false;
                }
            }
            if let Some(url) = url {
                if !selected.insert((family, url)) {
                    selection_valid = false;
                }
            }
        }
    }
    if expiry_valid && selection_valid && serde_json::to_value(operation).is_ok_and(|v| valid(&v)) {
        return Ok(());
    }
    let mut failure = Failure::new(Kind::Assertion, Phase::Transaction);
    if operation.is_read() {
        failure.outcome = Outcome::NotApplicable;
    }
    Err(failure)
}
/// Dispatch through the enclosing invocation's authority.
pub async fn execute(
    authority: &super::Authority,
    operation: Operation,
) -> worker::Result<Response> {
    match authority.bound(operation.id(), operation.is_read()).await? {
        super::authority::Backend::Postgres(env) => {
            let (cancel, deadline) = authority.context();
            let result = execute_postgres(env, &operation, cancel.clone(), deadline).await;
            result.map_err(|failure| {
                worker::Error::RustError(format!(
                    "storage_{}_{:?}_{:?}",
                    operation.id(),
                    failure.kind,
                    failure.outcome
                ))
            })
        }
    }
}

pub(crate) fn decode<T: serde::de::DeserializeOwned>(response: Response) -> worker::Result<T> {
    serde_json::from_value(response.value).map_err(Into::into)
}

pub(super) async fn execute_postgres(
    env: &worker::Env,
    operation: &Operation,
    cancel: opencast_worker_database_core::database::Cancellation,
    deadline: u64,
) -> super::Result<Response> {
    super::postgres::slice_c::execute(env, operation, cancel, deadline).await
}

/// Auth key reads and counter CAS use one authority. The PostgreSQL deadline is
/// shared across both segments; an uncertain CAS returns an error, never auth.
pub enum AttestAuthority<'a> {
    Postgres {
        env: &'a worker::Env,
        cancel: opencast_worker_database_core::database::Cancellation,
        deadline: u64,
    },
}
impl opencast_app_attest_core::app_attest_envelope::slice_c::AttestStorage for AttestAuthority<'_> {
    async fn read_key<'a>(
        &'a self,
        install: &'a str,
        key: &'a str,
    ) -> worker::Result<Option<opencast_app_attest_core::app_attest_storage::AppAttestKeyRow>> {
        match self {
            Self::Postgres {
                env,
                cancel,
                deadline,
            } => {
                let response = execute_postgres(
                    env,
                    &Operation::ReadKey {
                        install: install.into(),
                        key: key.into(),
                    },
                    cancel.clone(),
                    *deadline,
                )
                .await
                .map_err(auth_storage_error)?;
                if response.value.is_null() {
                    Ok(None)
                } else {
                    serde_json::from_value(response.value)
                        .map(Some)
                        .map_err(|_| worker::Error::RustError("invalid_identity_key_row".into()))
                }
            }
        }
    }
    async fn compare_and_advance_counter<'a>(
        &'a self,
        install: &'a str,
        key: &'a str,
        previous: i64,
        next: i64,
        now: i64,
    ) -> worker::Result<bool> {
        match self {
            Self::Postgres {
                env,
                cancel,
                deadline,
            } => execute_postgres(
                env,
                &Operation::AdvanceCounter {
                    install: install.into(),
                    key: key.into(),
                    previous,
                    next,
                    now,
                },
                cancel.clone(),
                *deadline,
            )
            .await
            .map_err(auth_storage_error)?
            .value
            .as_bool()
            .ok_or_else(|| worker::Error::RustError("invalid_identity_counter_result".into())),
        }
    }
}
/// The invocation's App Attest seam behind its identity gate: the key read
/// and the counter CAS each pass the gate before submitting anything.
pub struct GatedAttest<'a> {
    pub(super) authority: &'a super::Authority,
    pub(super) storage: AttestAuthority<'a>,
}
impl opencast_app_attest_core::app_attest_envelope::slice_c::AttestStorage for GatedAttest<'_> {
    async fn read_key<'a>(
        &'a self,
        install: &'a str,
        key: &'a str,
    ) -> worker::Result<Option<opencast_app_attest_core::app_attest_storage::AppAttestKeyRow>> {
        self.authority.bound("read_key", true).await?;
        self.storage.read_key(install, key).await
    }
    async fn compare_and_advance_counter<'a>(
        &'a self,
        install: &'a str,
        key: &'a str,
        previous: i64,
        next: i64,
        now: i64,
    ) -> worker::Result<bool> {
        self.authority.bound("advance_counter", false).await?;
        self.storage
            .compare_and_advance_counter(install, key, previous, next, now)
            .await
    }
}
fn auth_storage_error(error: Failure) -> worker::Error {
    worker::Error::RustError(format!(
        "identity_storage_{:?}_{:?}",
        error.kind, error.outcome
    ))
}

#[derive(Clone)]
pub(super) enum RecoveryProbe {
    Challenge(String),
    Key(String, String),
    Source(String, i64),
    Device(String, String),
    Install(String),
    Subscriptions(String, Vec<String>),
    Interests(String, Vec<String>),
    Feeds(Vec<String>),
    Catalog(Vec<String>),
    Admissions(Vec<String>),
    Secure(String),
    Push(String),
    DeletionFence(String),
    InstallCount(InstallFamily, String),
}
#[derive(Clone, Copy)]
pub(super) enum InstallFamily {
    Challenge,
    Key,
    DeliveryMember,
    Delivery,
    JobInterest,
    Interest,
    Legacy,
    Install,
    History,
    Push,
    Admission,
    Subscription,
    Device,
    Secure,
}
impl InstallFamily {
    pub(super) fn table(self) -> &'static str {
        match self {
            Self::Challenge => "app_attest_challenges",
            Self::Key => "app_attest_keys",
            Self::DeliveryMember => "n_delivery_member",
            Self::Delivery => "n_delivery",
            Self::JobInterest => "n_job_interest",
            Self::Interest => "n_interest",
            Self::Legacy => "n_legacy_bridge",
            Self::Install => "n_install",
            Self::History => "n_delivery_history",
            Self::Push => "push_send_attempts",
            Self::Admission => "feed_admission_attempts",
            Self::Subscription => "feed_subscriptions",
            Self::Device => "devices",
            Self::Secure => "secure_hello_attempts",
        }
    }
}
pub(super) fn recovery_probes(operation: &Operation) -> super::Result<Vec<RecoveryProbe>> {
    use Operation::*;
    use RecoveryProbe as P;
    validate(operation)?;
    let probes = match operation {
        IssueChallenge { id, .. } | ConsumeChallenge { id, .. } => vec![P::Challenge(id.clone())],
        RegisterKey {
            install,
            key,
            challenge,
            ..
        } => vec![
            P::Key(install.clone(), key.clone()),
            P::Challenge(challenge.clone()),
        ],
        AdvanceCounter { install, key, .. } => vec![P::Key(install.clone(), key.clone())],
        IncrementSource {
            source,
            window_start,
            ..
        } => vec![P::Source(source.clone(), *window_start)],
        DeleteIdentity { install } => vec![
            P::InstallCount(InstallFamily::Challenge, install.clone()),
            P::InstallCount(InstallFamily::Key, install.clone()),
        ],
        RegisterDevice { device: d } => vec![
            P::Device(d.install.clone(), d.token_hash.clone()),
            P::Install(d.install.clone()),
        ],
        DisableDevice {
            install,
            token_hash,
            ..
        } => vec![
            P::Device(install.clone(), token_hash.clone()),
            P::Install(install.clone()),
        ],
        SecureAttempt { id, .. } => vec![P::Secure(id.clone())],
        PushAttempt { id, .. } => vec![P::Push(id.clone())],
        SyncSubscriptions { writes } => {
            let mut selected = std::collections::BTreeMap::<String, Vec<String>>::new();
            let mut feeds = vec![];
            let mut admissions = vec![];
            for write in writes {
                match write {
                    SubscriptionWrite::EnsureFeed { url, .. }
                    | SubscriptionWrite::PendingFeed { url, .. } => feeds.push(url.clone()),
                    SubscriptionWrite::Attempt { attempt } => admissions.push(attempt.id.clone()),
                    SubscriptionWrite::Upsert { install, url, .. }
                    | SubscriptionWrite::MarkDeleted { install, url, .. } => selected
                        .entry(install.clone())
                        .or_default()
                        .push(url.clone()),
                }
            }
            let mut probes = vec![];
            for (install, urls) in selected {
                let ids = urls
                    .iter()
                    .map(|url| crate::delivery::wire::hash(&["feed-v1", url]))
                    .collect();
                probes.push(P::Subscriptions(install.clone(), urls));
                probes.push(P::Interests(install, ids));
            }
            if !feeds.is_empty() {
                probes.push(P::Feeds(feeds.clone()));
                probes.push(P::Catalog(feeds));
            }
            if !admissions.is_empty() {
                probes.push(P::Admissions(admissions));
            }
            probes
        }
        EraseInstall { install, fence, .. } => {
            let mut probes = vec![P::DeletionFence(fence.clone())];
            for family in [
                InstallFamily::DeliveryMember,
                InstallFamily::Delivery,
                InstallFamily::JobInterest,
                InstallFamily::Interest,
                InstallFamily::Legacy,
                InstallFamily::Install,
                InstallFamily::History,
                InstallFamily::Push,
                InstallFamily::Admission,
                InstallFamily::Subscription,
                InstallFamily::Device,
                InstallFamily::Secure,
                InstallFamily::Challenge,
                InstallFamily::Key,
            ] {
                probes.push(P::InstallCount(family, install.clone()));
            }
            probes
        }
        _ => return Err(Failure::new(Kind::Assertion, Phase::Read)),
    };
    Ok(probes)
}
pub(super) fn recovery_result(operation: &Operation, mut observations: Vec<Value>) -> Value {
    // Each observation is an unordered readback rowset. Preserve values and byte
    // arrays; sort whole rows only, never the arrays or text inside a row.
    for observation in &mut observations {
        if let Some(rows) = observation.get_mut("rows").and_then(Value::as_array_mut) {
            rows.sort_by_key(Value::to_string);
        }
    }
    let unresolved = if matches!(operation, Operation::EraseInstall { .. }) {
        vec!["n_event", "n_group_member", "n_requester_ticket"]
    } else {
        vec![]
    };
    // A later view cannot attribute a counter CAS or reconstruct deleted job
    // identities after a possibly partial failed BEGIN. Never certify a retry.
    serde_json::json!({"operation":operation.id(),"outcome":"unknown","certainty":"inconclusive",
        "unresolved_without_predeletion_job_identities":unresolved,"observations":observations})
}
pub async fn reconcile_postgres(
    env: &worker::Env,
    operation: &Operation,
    cancel: opencast_worker_database_core::database::Cancellation,
    deadline: u64,
) -> super::Result<Value> {
    super::postgres::slice_c::reconcile(env, operation, cancel, deadline).await
}
