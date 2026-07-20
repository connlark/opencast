use serde::{Deserialize, Serialize};

use crate::types::AdAnalysisRequest;
use crate::usage::UsageLimitProfile;

pub const JOB_BINDING: &str = "AD_ANALYSIS_JOB";
pub const JOB_RESULT_TTL_SECONDS: i64 = 1_800;
pub const JOB_RUNNING_DEADLINE_SECONDS: i64 = 600;
pub const JOB_HEARTBEAT_SECONDS: u64 = 30;
pub const JOB_SUBMIT_POLL_AFTER_SECONDS: u64 = 15;
pub const JOB_POLL_AFTER_SECONDS: u64 = 10;

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum JobRecord {
    Running {
        job_id: String,
        started_at: i64,
    },
    Completed {
        job_id: String,
        result_json: String,
        purge_at: i64,
    },
    FailedUpstream {
        job_id: String,
        status: u16,
        code: String,
        purge_at: i64,
    },
    FailedTransient {
        job_id: String,
        purge_at: i64,
    },
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct JobSubmitRequest {
    pub usage_object_name: String,
    pub usage_profile: UsageLimitProfile,
    pub estimated_input_tokens: u64,
    pub request: AdAnalysisRequest,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct JobPollRequest {
    pub job_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SubmitDecision {
    Start,
    Attach { job_id: String },
    ServeCompleted { job_id: String, result_json: String },
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

pub fn submit_decision(record: Option<&JobRecord>) -> SubmitDecision {
    match record {
        Some(JobRecord::Running { job_id, .. }) => SubmitDecision::Attach {
            job_id: job_id.clone(),
        },
        Some(JobRecord::Completed {
            job_id,
            result_json,
            ..
        }) => SubmitDecision::ServeCompleted {
            job_id: job_id.clone(),
            result_json: result_json.clone(),
        },
        Some(JobRecord::FailedUpstream { .. } | JobRecord::FailedTransient { .. }) | None => {
            SubmitDecision::Start
        }
    }
}

pub fn poll_decision(record: Option<&JobRecord>) -> PollDecision {
    match record {
        Some(JobRecord::Running { job_id, .. }) => PollDecision::Running {
            job_id: job_id.clone(),
        },
        Some(JobRecord::Completed {
            job_id,
            result_json,
            ..
        }) => PollDecision::ServeCompleted {
            job_id: job_id.clone(),
            result_json: result_json.clone(),
        },
        Some(JobRecord::FailedUpstream { status, code, .. }) => PollDecision::ServeFailedUpstream {
            status: *status,
            code: code.clone(),
        },
        Some(JobRecord::FailedTransient { .. }) => PollDecision::ServeFailedTransient,
        None => PollDecision::NotFound,
    }
}

pub fn alarm_decision(record: Option<&JobRecord>, run_active: bool, now: i64) -> AlarmDecision {
    match record {
        Some(JobRecord::Running { job_id, started_at })
            if !run_active || now >= started_at.saturating_add(JOB_RUNNING_DEADLINE_SECONDS) =>
        {
            AlarmDecision::FailTransient {
                record: JobRecord::FailedTransient {
                    job_id: job_id.clone(),
                    purge_at: now.saturating_add(JOB_RESULT_TTL_SECONDS),
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
