//! Closed polling storage requests. Callers supply domain values, never SQL.
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Candidates {
    Repairs,
    Recurring,
    Baselines,
    Maintenance,
}
#[derive(Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReservationMode {
    Admission,
    Repair,
    Maintenance,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Candidate {
    pub feed_id: String,
    pub origin_key: String,
    pub admission_origin: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EnqueueIdentity {
    pub feed_id: String,
    pub generation: i64,
}
#[derive(Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Control {
    DispatcherAdmission,
    FeedObservation,
    EpisodeActivation,
    EpisodeSend,
    JobEnrollment,
    JobSend,
    Cleanup,
    DiagnosticSend,
    FiveMinutePolling,
}
impl Control {
    pub(super) fn name(self) -> &'static str {
        match self {
            Self::DispatcherAdmission => "dispatcher_admission",
            Self::FeedObservation => "feed_observation",
            Self::EpisodeActivation => "episode_activation",
            Self::EpisodeSend => "episode_send",
            Self::JobEnrollment => "job_enrollment",
            Self::JobSend => "job_send",
            Self::Cleanup => "cleanup",
            Self::DiagnosticSend => "diagnostic_send",
            Self::FiveMinutePolling => "five_minute_polling",
        }
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum AlertMarker {
    Armed {
        now: i64,
    },
    Onset {
        since: i64,
    },
    OnsetSent {
        since: i64,
        now: i64,
    },
    ClaimHourly {
        since: i64,
        previous: i64,
        marker: i64,
    },
    FinishHourly {
        expected: i64,
        value: i64,
    },
    Recovery {
        since: i64,
    },
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Fence {
    pub feed: String,
    pub epoch: i64,
    pub generation: i64,
}

#[derive(Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Counter {
    PublisherFailures,
    HandlingFailures,
    Redeliveries,
    DeadLetters,
    StaleCommits,
    RetryAfterClamps,
    ScanBusy,
    PermitReclaims,
}
impl Counter {
    pub(super) fn column(self) -> &'static str {
        match self {
            Self::PublisherFailures => "publisher_failures",
            Self::HandlingFailures => "handling_failures",
            Self::Redeliveries => "redeliveries",
            Self::DeadLetters => "dead_letters",
            Self::StaleCommits => "stale_commits",
            Self::RetryAfterClamps => "retry_after_clamps",
            Self::ScanBusy => "scan_busy",
            Self::PermitReclaims => "permit_reclaims",
        }
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
pub enum Operation {
    ReadControl {
        control: Control,
    },
    AbandonIneligible,
    ReadCandidates {
        class: Candidates,
        now: i64,
    },
    ReserveDispatch {
        candidates: Vec<Candidate>,
        mode: ReservationMode,
        now: i64,
    },
    LapseUncertainEnqueue {
        identities: Vec<EnqueueIdentity>,
        now: i64,
    },
    ReadRollup {
        now: i64,
    },
    ReadStats {
        now: i64,
    },
    ReadWatchdog {
        now: i64,
    },
    ReadDispatchState {
        full: bool,
    },
    MarkAlert {
        marker: AlertMarker,
    },
    ReadValidators {
        feed: String,
    },
    ReadFeedSource {
        url: String,
    },
    ReadScanCheckpoint {
        feed: String,
        poll: Option<Fence>,
        now: i64,
    },
    SettleUnchanged {
        proof: super::observations::Unchanged,
        now: i64,
    },
    ReadUnchangedFence {
        checkpoint: super::observations::Checkpoint,
        now: i64,
    },
    RecordFailedScan {
        bound: super::observations::Bound,
        reservation: super::observations::Reservation,
    },
    ReadClaim {
        fence: Fence,
        now: i64,
    },
    ReadOrigin {
        fence: Fence,
        origin: String,
        now: i64,
    },
    RecordOriginFailure {
        fence: Fence,
        origin: String,
        until: i64,
        status: i64,
        now: i64,
    },
    RecordOriginRecovery {
        fence: Fence,
        origin: String,
        status: i64,
        now: i64,
    },
    SettlePublisherFailure {
        fence: Fence,
        reason: String,
        now: i64,
    },
    SettleCooldown {
        fence: Fence,
        until: i64,
        now: i64,
    },
    SettleIdle {
        fence: Fence,
        now: i64,
    },
    RenewContinuation {
        fence: Fence,
        delay: i64,
        now: i64,
    },
    ReleaseAttempt {
        fence: Fence,
        lease: Option<String>,
        outcome: String,
        reason: String,
        now: i64,
    },
    SettleDeadLetter {
        fence: Fence,
        now: i64,
    },
    RecordPollStat {
        counter: Counter,
        now: i64,
    },
}
impl Operation {
    pub fn id(&self) -> &'static str {
        match self {
            Self::ReadControl { .. }
            | Self::AbandonIneligible
            | Self::ReadCandidates { .. }
            | Self::MarkAlert { .. } => "A01",
            Self::ReserveDispatch { .. } => "A02",
            Self::LapseUncertainEnqueue { .. } => "A03",
            Self::ReadRollup { .. }
            | Self::ReadStats { .. }
            | Self::ReadWatchdog { .. }
            | Self::ReadDispatchState { .. } => "A14",
            Self::ReadValidators { .. }
            | Self::ReadFeedSource { .. }
            | Self::ReadScanCheckpoint { .. } => "A05",
            Self::SettleUnchanged { .. } | Self::ReadUnchangedFence { .. } => "A08",
            Self::RecordFailedScan { .. } => "A09",
            Self::ReadClaim { .. } => "A04",
            Self::ReadOrigin { .. } => "A06",
            Self::RecordOriginFailure { .. } | Self::RecordOriginRecovery { .. } => "A07",
            Self::SettlePublisherFailure { .. }
            | Self::SettleCooldown { .. }
            | Self::SettleIdle { .. } => "A10",
            Self::RenewContinuation { .. } => "A11",
            Self::ReleaseAttempt { .. } | Self::SettleDeadLetter { .. } => "A12",
            Self::RecordPollStat { .. } => "A13",
        }
    }
    pub fn is_read(&self) -> bool {
        matches!(
            self,
            Self::ReadControl { .. }
                | Self::ReadCandidates { .. }
                | Self::ReadRollup { .. }
                | Self::ReadStats { .. }
                | Self::ReadWatchdog { .. }
                | Self::ReadDispatchState { .. }
                | Self::ReadClaim { .. }
                | Self::ReadOrigin { .. }
                | Self::ReadValidators { .. }
                | Self::ReadFeedSource { .. }
                | Self::ReadScanCheckpoint { .. }
                | Self::ReadUnchangedFence { .. }
        )
    }
}
