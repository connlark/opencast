use opencast_app_attest_core::app_attest::sha256_hex;
use serde::{Deserialize, Serialize};

use crate::billing::{BillingContext, JobBillingState, PendingBillingAction};
use crate::types::{
    TranscriptAnalysisRequest, TranscriptAnalysisResponse, TranscriptMetadata, TranscriptSegment,
};
use crate::usage::UsageLimitProfile;

pub const JOB_BINDING: &str = "TRANSCRIPT_ANALYSIS_JOB";
pub const JOB_RESULT_TTL_SECONDS: i64 = 1_800;
pub const JOB_RUNNING_DEADLINE_SECONDS: i64 = 600;
pub const JOB_HEARTBEAT_SECONDS: u64 = 30;
pub const JOB_SUBMIT_POLL_AFTER_SECONDS: u64 = 15;
pub const JOB_POLL_AFTER_SECONDS: u64 = 10;

/// The job DO is keyed by the caller-supplied transcript fingerprint, so a
/// record binds the subjects entitled to it plus a server-computed hash of
/// the transcript content. Membership gates polls; content possession
/// (matching hash) is the proof of entitlement that lets a new subject join
/// an existing job — same-content dedupe survives, blind attach by computed
/// name does not. This join gate is also the seam a future durable
/// shared-artifact store can extend.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum JobRecord {
    Running {
        job_id: String,
        started_at: i64,
        #[serde(default)]
        subjects: Vec<String>,
        #[serde(default)]
        content_hash: String,
        /// Reserve bookkeeping (fresh `tan-` billing id per run attempt).
        /// Persisted BEFORE the run task spawns so any terminalizer — the
        /// run task, the failed-run recovery, or the alarm watchdog — can
        /// settle or release the reservation. Defaulted for deploy skew.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        billing: Option<JobBillingState>,
    },
    Completed {
        job_id: String,
        result_json: String,
        purge_at: i64,
        #[serde(default)]
        subjects: Vec<String>,
        #[serde(default)]
        content_hash: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        billing: Option<JobBillingState>,
    },
    FailedUpstream {
        job_id: String,
        status: u16,
        code: String,
        purge_at: i64,
        #[serde(default)]
        subjects: Vec<String>,
        #[serde(default)]
        content_hash: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        billing: Option<JobBillingState>,
    },
    FailedTransient {
        job_id: String,
        purge_at: i64,
        #[serde(default)]
        subjects: Vec<String>,
        #[serde(default)]
        content_hash: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        billing: Option<JobBillingState>,
    },
}

impl JobRecord {
    pub fn subjects(&self) -> &[String] {
        match self {
            JobRecord::Running { subjects, .. }
            | JobRecord::Completed { subjects, .. }
            | JobRecord::FailedUpstream { subjects, .. }
            | JobRecord::FailedTransient { subjects, .. } => subjects,
        }
    }

    pub fn content_hash(&self) -> &str {
        match self {
            JobRecord::Running { content_hash, .. }
            | JobRecord::Completed { content_hash, .. }
            | JobRecord::FailedUpstream { content_hash, .. }
            | JobRecord::FailedTransient { content_hash, .. } => content_hash,
        }
    }

    /// Adds a subject to the record's authorized set. Returns true when the
    /// set changed (caller persists), false when already present.
    pub fn push_subject(&mut self, subject: &str) -> bool {
        let subjects = match self {
            JobRecord::Running { subjects, .. }
            | JobRecord::Completed { subjects, .. }
            | JobRecord::FailedUpstream { subjects, .. }
            | JobRecord::FailedTransient { subjects, .. } => subjects,
        };
        if subject.is_empty() || subjects.iter().any(|existing| existing == subject) {
            return false;
        }
        subjects.push(subject.to_string());
        true
    }

    pub fn billing(&self) -> Option<&JobBillingState> {
        match self {
            JobRecord::Running { billing, .. }
            | JobRecord::Completed { billing, .. }
            | JobRecord::FailedUpstream { billing, .. }
            | JobRecord::FailedTransient { billing, .. } => billing.as_ref(),
        }
    }

    pub fn billing_mut(&mut self) -> Option<&mut JobBillingState> {
        match self {
            JobRecord::Running { billing, .. }
            | JobRecord::Completed { billing, .. }
            | JobRecord::FailedUpstream { billing, .. }
            | JobRecord::FailedTransient { billing, .. } => billing.as_mut(),
        }
    }

    pub fn purge_at(&self) -> Option<i64> {
        match self {
            JobRecord::Running { .. } => None,
            JobRecord::Completed { purge_at, .. }
            | JobRecord::FailedUpstream { purge_at, .. }
            | JobRecord::FailedTransient { purge_at, .. } => Some(*purge_at),
        }
    }

    /// A skew-window submit that carried no subject leaves the set empty;
    /// such records keep the open behavior until their TTL purge — at most
    /// 30 minutes.
    fn legacy_open(&self) -> bool {
        self.subjects().is_empty()
    }

    fn authorizes(&self, subject: &str) -> bool {
        self.legacy_open() || self.subjects().iter().any(|existing| existing == subject)
    }
}

/// Server-side identity of the transcript content a job was created from:
/// the transcript metadata plus every segment, exactly the payload subtree
/// the client fingerprint stands for. Serialization of equal parsed values
/// is deterministic, so equal content always agrees; the sentinel on the
/// (unreachable) serialization failure is non-empty so it can never read as
/// a legacy record. NOTE: this is the 30-minute idempotency join key, NOT
/// the future sharing content key — the durable share store hashes normalized
/// segment text only, deliberately excluding timings and metadata
/// so identity deduplication and content sharing remain separate mechanisms.
pub fn transcript_content_hash(
    transcript: &TranscriptMetadata,
    segments: &[TranscriptSegment],
) -> String {
    match serde_json::to_string(&(transcript, segments)) {
        Ok(serialized) => sha256_hex(serialized.as_bytes()),
        Err(_) => "unserializable-content".to_string(),
    }
}

/// One structured line per successful analysis, emitted the moment model work
/// completes — before the terminal-write guard, because the model spend has
/// happened even if the result is later discarded. Content-free by
/// construction: counts, fixed warning codes, and token usage only, never
/// transcript or model text. While results stay client-side this is the only
/// server-side per-run cost record.
pub fn completion_log_line(
    response: &TranscriptAnalysisResponse,
    raw_segment_count: usize,
    model_unit_count: usize,
    attempts: usize,
    elapsed_ms: u64,
) -> String {
    let usage = response.usage.as_ref();
    serde_json::json!({
        "event": "transcript_analysis_completed",
        "request_id": response.request_id,
        "model": response.model,
        "segments": raw_segment_count,
        "model_units": model_unit_count,
        "attempts": attempts,
        "elapsed_ms": elapsed_ms,
        "chapters": response.chapters.len(),
        "claims": response
            .summary
            .as_ref()
            .map_or(0, |summary| summary.claims.len()),
        "warnings": response.warnings,
        "prompt_tokens": usage.map(|usage| usage.prompt_token_count),
        "candidates_tokens": usage.map(|usage| usage.candidates_token_count),
        "thoughts_tokens": usage.map(|usage| usage.thoughts_token_count),
        "total_tokens": usage.map(|usage| usage.total_token_count),
    })
    .to_string()
}

/// The subject strings are server-derived per authenticated lane and never
/// taken from request payloads. Prefixes keep lanes collision-free.
pub fn app_attest_subject(key_id_hash: &str) -> String {
    format!("app-attest-key:{key_id_hash}")
}

pub fn bearer_subject(token_hash: &str) -> String {
    format!("bearer:{token_hash}")
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct JobSubmitRequest {
    pub usage_object_name: String,
    pub usage_profile: UsageLimitProfile,
    pub estimated_input_tokens: u64,
    /// Server-derived caller identity recorded on the job. Defaulted so a
    /// deploy-skew submit from a previous worker version still parses (its
    /// job is then legacy-open until purge).
    #[serde(default)]
    pub subject: String,
    /// Server-resolved billing directive. `None` on the
    /// billing-exempt bearer lane and while `BILLING_REQUIRED` is dark;
    /// defaulted for deploy skew.
    #[serde(default)]
    pub billing: Option<BillingContext>,
    pub request: TranscriptAnalysisRequest,
}

/// Public poll body (envelope payload and bearer path): exactly the job id.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct JobPollRequest {
    pub job_id: String,
}

/// Worker → job-DO poll body. Built fresh server-side per request — the
/// subject can never be smuggled in through a client payload.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct JobDoPollRequest {
    pub job_id: String,
    #[serde(default)]
    pub subject: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SubmitDecision {
    Start,
    Attach {
        job_id: String,
        /// True when the subject proved content possession and must be
        /// persisted into the record's authorized set.
        join: bool,
    },
    ServeCompleted {
        job_id: String,
        result_json: String,
        join: bool,
    },
    /// Submit whose content does not match the stored job under the same
    /// fingerprint: blind attach / poisoning attempt.
    DenyContentMismatch,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PollDecision {
    NotFound,
    Running { job_id: String },
    ServeCompleted { job_id: String, result_json: String },
    ServeFailedUpstream { status: u16, code: String },
    ServeFailedTransient,
}

#[derive(Debug, Clone, PartialEq)]
pub enum AlarmDecision {
    Purge,
    Heartbeat,
    SchedulePurge { purge_at: i64 },
    FailTransient { record: JobRecord },
    /// A terminal record still carries an unresolved settle/release: attempt
    /// it under the bounded budget before the purge deadline.
    RetryBilling,
}

pub fn valid_job_id(value: &str) -> bool {
    (8..=128).contains(&value.len())
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

pub fn job_object_name(job_id: &str) -> String {
    format!("transcript-analysis:v1:job:{job_id}")
}

pub fn submit_decision(
    record: Option<&JobRecord>,
    subject: &str,
    content_hash: &str,
) -> SubmitDecision {
    let Some(record) = record else {
        return SubmitDecision::Start;
    };

    // An already-authorized subject (or a legacy-open record) re-attaches
    // without a content check: it owns the job. A new subject must prove
    // possession of the exact stored content to join.
    let authorized = record.authorizes(subject);
    let content_matches = !record.legacy_open() && record.content_hash() == content_hash;
    let join = !authorized && content_matches;

    match record {
        JobRecord::Running { job_id, .. } => {
            if authorized || content_matches {
                SubmitDecision::Attach {
                    job_id: job_id.clone(),
                    join,
                }
            } else {
                SubmitDecision::DenyContentMismatch
            }
        }
        JobRecord::Completed {
            job_id,
            result_json,
            ..
        } => {
            if authorized || content_matches {
                SubmitDecision::ServeCompleted {
                    job_id: job_id.clone(),
                    result_json: result_json.clone(),
                    join,
                }
            } else {
                SubmitDecision::DenyContentMismatch
            }
        }
        JobRecord::FailedUpstream { .. } | JobRecord::FailedTransient { .. } => {
            SubmitDecision::Start
        }
    }
}

/// An unauthorized subject gets the same `NotFound` a nonexistent job
/// produces — no existence oracle, and no reaching the purge-on-serve
/// failure paths.
pub fn poll_decision(record: Option<&JobRecord>, subject: Option<&str>) -> PollDecision {
    let Some(record) = record else {
        return PollDecision::NotFound;
    };
    if let Some(subject) = subject {
        if !record.authorizes(subject) {
            return PollDecision::NotFound;
        }
    }
    match record {
        JobRecord::Running { job_id, .. } => PollDecision::Running {
            job_id: job_id.clone(),
        },
        JobRecord::Completed {
            job_id,
            result_json,
            ..
        } => PollDecision::ServeCompleted {
            job_id: job_id.clone(),
            result_json: result_json.clone(),
        },
        JobRecord::FailedUpstream { status, code, .. } => PollDecision::ServeFailedUpstream {
            status: *status,
            code: code.clone(),
        },
        JobRecord::FailedTransient { .. } => PollDecision::ServeFailedTransient,
    }
}

/// Single home for the settle-vs-release rule: a delivered result settles
/// its reservation, every failure releases it. `None` when the record
/// carries no billing.
pub fn terminal_billing_action(record: &JobRecord) -> Option<PendingBillingAction> {
    record.billing()?;
    Some(match record {
        JobRecord::Completed { .. } => PendingBillingAction::Settle,
        _ => PendingBillingAction::Release,
    })
}

pub fn alarm_decision(record: Option<&JobRecord>, run_active: bool, now: i64) -> AlarmDecision {
    match record {
        Some(JobRecord::Running {
            job_id,
            started_at,
            subjects,
            content_hash,
            billing,
        }) if !run_active || now >= started_at.saturating_add(JOB_RUNNING_DEADLINE_SECONDS) => {
            // A watchdogged run still holds its reservation (nothing else
            // will release it — the run task is gone). The billing state is
            // carried through unchanged: the shared terminal-billing path
            // derives the release from the failure variant and stamps its
            // own pending marker before the first attempt.
            AlarmDecision::FailTransient {
                record: JobRecord::FailedTransient {
                    job_id: job_id.clone(),
                    purge_at: now.saturating_add(JOB_RESULT_TTL_SECONDS),
                    subjects: subjects.clone(),
                    content_hash: content_hash.clone(),
                    billing: billing.clone(),
                },
            }
        }
        Some(JobRecord::Running { .. }) => AlarmDecision::Heartbeat,
        // Unresolved settle/release on a live terminal record beats the
        // purge schedule; at/after the purge deadline the purge path makes
        // one final attempt instead (bounded either way).
        Some(record @ (JobRecord::Completed { purge_at, .. }
        | JobRecord::FailedUpstream { purge_at, .. }
        | JobRecord::FailedTransient { purge_at, .. }))
            if now < *purge_at =>
        {
            if record
                .billing()
                .is_some_and(|billing| billing.pending.is_some())
            {
                AlarmDecision::RetryBilling
            } else {
                AlarmDecision::SchedulePurge {
                    purge_at: *purge_at,
                }
            }
        }
        Some(
            JobRecord::Completed { .. }
            | JobRecord::FailedUpstream { .. }
            | JobRecord::FailedTransient { .. },
        )
        | None => AlarmDecision::Purge,
    }
}
