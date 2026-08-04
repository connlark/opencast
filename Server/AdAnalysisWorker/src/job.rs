use opencast_app_attest_core::app_attest::sha256_hex;
use serde::{Deserialize, Serialize};

use crate::types::{AdAnalysisRequest, TranscriptMetadata, TranscriptSegment};
use crate::usage::UsageLimitProfile;

pub const JOB_BINDING: &str = "AD_ANALYSIS_JOB";
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
/// name does not. Records written before this scheme (`subjects` empty via
/// serde default) stay readable and are grandfathered until their TTL purge.
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
    },
    Completed {
        job_id: String,
        result_json: String,
        purge_at: i64,
        #[serde(default)]
        subjects: Vec<String>,
        #[serde(default)]
        content_hash: String,
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
    },
    FailedTransient {
        job_id: String,
        purge_at: i64,
        #[serde(default)]
        subjects: Vec<String>,
        #[serde(default)]
        content_hash: String,
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

    /// Pre-scheme records (and skew-window submits that carried no subject)
    /// have an empty subject set and keep the old open behavior until their
    /// TTL purge — at most 30 minutes after deploy.
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
/// a legacy record.
pub fn transcript_content_hash(
    transcript: &TranscriptMetadata,
    segments: &[TranscriptSegment],
) -> String {
    match serde_json::to_string(&(transcript, segments)) {
        Ok(serialized) => sha256_hex(serialized.as_bytes()),
        Err(_) => "unserializable-content".to_string(),
    }
}

/// The subject strings are server-derived per authenticated lane and never
/// taken from request payloads. Prefixes keep lanes collision-free.
pub fn app_attest_subject(key_id_hash: &str) -> String {
    format!("app-attest-key:{key_id_hash}")
}

pub fn bearer_subject(token_hash: &str) -> String {
    format!("bearer:{token_hash}")
}

pub fn transcription_account_subject(account_id_hash: &str) -> String {
    format!("transcription-account:{account_id_hash}")
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
    /// True only for the service-binding internal lane: on a content
    /// mismatch a trusted submit replaces the squatting job instead of
    /// being denied, so a name-squatter cannot deny service to RTW.
    #[serde(default)]
    pub internal: bool,
    pub request: AdAnalysisRequest,
}

/// Public poll body (envelope payload and bearer path): unchanged wire
/// shape, exactly the job id.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct JobPollRequest {
    pub job_id: String,
}

/// Worker → job-DO poll body. Built fresh server-side per request — the
/// subject can never be smuggled in through a client payload. `None` means
/// the host-gated internal lane (trusted).
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct JobDoPollRequest {
    pub job_id: String,
    #[serde(default)]
    pub subject: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SubmitDecision {
    Start,
    /// Internal-lane submit found the name occupied by different content:
    /// drop the squatter's record and start fresh with the trusted content.
    Replace,
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
    /// Public submit whose content does not match the stored job under the
    /// same fingerprint: blind attach / poisoning attempt.
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
}

pub fn valid_job_id(value: &str) -> bool {
    (8..=128).contains(&value.len())
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

pub fn job_object_name(job_id: &str) -> String {
    format!("ad-analysis:v1:job:{job_id}")
}

pub fn submit_decision(
    record: Option<&JobRecord>,
    subject: &str,
    content_hash: &str,
    internal: bool,
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
            } else if internal {
                SubmitDecision::Replace
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
            } else if internal {
                SubmitDecision::Replace
            } else {
                SubmitDecision::DenyContentMismatch
            }
        }
        JobRecord::FailedUpstream { .. } | JobRecord::FailedTransient { .. } => {
            SubmitDecision::Start
        }
    }
}

/// `subject` is `None` only for the host-gated internal lane, which may
/// poll any job. An unauthorized public subject gets the same `NotFound` a
/// nonexistent job produces — no existence oracle, and no reaching the
/// purge-on-serve failure paths.
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

pub fn alarm_decision(record: Option<&JobRecord>, run_active: bool, now: i64) -> AlarmDecision {
    match record {
        Some(JobRecord::Running {
            job_id,
            started_at,
            subjects,
            content_hash,
        }) if !run_active || now >= started_at.saturating_add(JOB_RUNNING_DEADLINE_SECONDS) => {
            AlarmDecision::FailTransient {
                record: JobRecord::FailedTransient {
                    job_id: job_id.clone(),
                    purge_at: now.saturating_add(JOB_RESULT_TTL_SECONDS),
                    subjects: subjects.clone(),
                    content_hash: content_hash.clone(),
                },
            }
        }
        Some(JobRecord::Running { .. }) => AlarmDecision::Heartbeat,
        Some(
            JobRecord::Completed { purge_at, .. }
            | JobRecord::FailedUpstream { purge_at, .. }
            | JobRecord::FailedTransient { purge_at, .. },
        ) if now < *purge_at => AlarmDecision::SchedulePurge {
            purge_at: *purge_at,
        },
        Some(
            JobRecord::Completed { .. }
            | JobRecord::FailedUpstream { .. }
            | JobRecord::FailedTransient { .. },
        )
        | None => AlarmDecision::Purge,
    }
}
