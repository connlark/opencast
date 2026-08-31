use opencast_transcript_analysis_worker::billing::{JobBillingState, PendingBillingAction};
use opencast_transcript_analysis_worker::job::{
    alarm_decision, app_attest_subject, bearer_subject, completion_log_line, job_object_name,
    poll_decision, submit_decision, terminal_billing_action, transcript_content_hash,
    valid_job_id, AlarmDecision, JobRecord, PollDecision, SubmitDecision, JOB_RESULT_TTL_SECONDS,
    JOB_RUNNING_DEADLINE_SECONDS,
};
use opencast_transcript_analysis_worker::types::{
    GeminiUsage, TranscriptAnalysisResponse, TranscriptMetadata, TranscriptSegment,
    ValidatedChapter, ValidatedClaim, ValidatedSummary,
};

const OWNER: &str = "app-attest-key:owner-hash";
const STRANGER: &str = "app-attest-key:stranger-hash";
const CONTENT: &str = "content-hash-aaaa";
const OTHER_CONTENT: &str = "content-hash-bbbb";

fn running() -> JobRecord {
    JobRecord::Running {
        job_id: "fingerprint-123".to_string(),
        started_at: 100,
        subjects: vec![OWNER.to_string()],
        content_hash: CONTENT.to_string(),
        billing: None,
    }
}

fn completed() -> JobRecord {
    JobRecord::Completed {
        job_id: "fingerprint-123".to_string(),
        result_json: "result".to_string(),
        purge_at: 2_000,
        subjects: vec![OWNER.to_string()],
        content_hash: CONTENT.to_string(),
        billing: None,
    }
}

#[test]
fn job_record_serde_round_trips_every_state() {
    let records = [
        running(),
        completed(),
        JobRecord::FailedUpstream {
            job_id: "fingerprint-123".to_string(),
            status: 503,
            code: "gemini_retry_exhausted".to_string(),
            purge_at: 2_000,
            subjects: vec![OWNER.to_string()],
            content_hash: CONTENT.to_string(),
            billing: None,
        },
        JobRecord::FailedTransient {
            job_id: "fingerprint-123".to_string(),
            purge_at: 2_000,
            subjects: vec![OWNER.to_string()],
            content_hash: CONTENT.to_string(),
            billing: None,
        },
    ];

    for record in records {
        let encoded = serde_json::to_string(&record).expect("record serializes");
        assert!(encoded.contains(r#""state":"#));
        assert!(!encoded.contains("transcript\""));
        let decoded: JobRecord = serde_json::from_str(&encoded).expect("record deserializes");
        assert_eq!(decoded, record);
    }
}

/// A skew-window submit that carried no subject leaves the set empty; such
/// records must deserialize and behave open until their TTL purge.
#[test]
fn subjectless_records_deserialize_and_stay_open_until_purge() {
    let legacy_running: JobRecord =
        serde_json::from_str(r#"{"state":"running","job_id":"fingerprint-123","started_at":100}"#)
            .expect("subjectless record deserializes");
    assert_eq!(legacy_running.subjects(), &[] as &[String]);
    assert_eq!(legacy_running.content_hash(), "");

    assert!(matches!(
        poll_decision(Some(&legacy_running), Some(STRANGER)),
        PollDecision::Running { .. }
    ));
    assert!(matches!(
        submit_decision(Some(&legacy_running), STRANGER, OTHER_CONTENT),
        SubmitDecision::Attach { join: false, .. }
    ));
}

#[test]
fn submit_same_subject_reattaches_without_content_check() {
    assert_eq!(
        submit_decision(Some(&running()), OWNER, OTHER_CONTENT),
        SubmitDecision::Attach {
            job_id: "fingerprint-123".to_string(),
            join: false,
        }
    );
    assert!(matches!(
        submit_decision(Some(&completed()), OWNER, OTHER_CONTENT),
        SubmitDecision::ServeCompleted { join: false, .. }
    ));
}

/// The cost-sharing seam: a new subject that possesses
/// the exact stored content joins the job (and the join must be persisted).
#[test]
fn submit_content_matched_new_subject_joins() {
    assert_eq!(
        submit_decision(Some(&running()), STRANGER, CONTENT),
        SubmitDecision::Attach {
            job_id: "fingerprint-123".to_string(),
            join: true,
        }
    );
    assert!(matches!(
        submit_decision(Some(&completed()), STRANGER, CONTENT),
        SubmitDecision::ServeCompleted { join: true, .. }
    ));

    let mut record = running();
    assert!(record.push_subject(STRANGER));
    assert!(!record.push_subject(STRANGER));
    assert!(matches!(
        poll_decision(Some(&record), Some(STRANGER)),
        PollDecision::Running { .. }
    ));
}

/// Blind attach / poisoning: same fingerprint, different content — denied.
/// With no internal lane there is no Replace path; every mismatch denies.
#[test]
fn submit_content_mismatch_is_always_denied() {
    assert_eq!(
        submit_decision(Some(&running()), STRANGER, OTHER_CONTENT),
        SubmitDecision::DenyContentMismatch
    );
    assert_eq!(
        submit_decision(Some(&completed()), STRANGER, OTHER_CONTENT),
        SubmitDecision::DenyContentMismatch
    );
}

#[test]
fn submit_failed_records_always_restart() {
    let failed = JobRecord::FailedTransient {
        job_id: "fingerprint-123".to_string(),
        purge_at: 2_000,
        subjects: vec![OWNER.to_string()],
        content_hash: CONTENT.to_string(),
        billing: None,
    };
    assert_eq!(
        submit_decision(Some(&failed), STRANGER, OTHER_CONTENT),
        SubmitDecision::Start
    );
    assert_eq!(
        submit_decision(None, OWNER, CONTENT),
        SubmitDecision::Start
    );
}

/// A subject that computed a job's DO name but is not in the subject set
/// gets the same NotFound a nonexistent job produces — polls, results, and
/// the purge-on-serve failure paths are all unreachable.
#[test]
fn poll_unauthorized_subject_sees_not_found() {
    for record in [
        running(),
        completed(),
        JobRecord::FailedUpstream {
            job_id: "fingerprint-123".to_string(),
            status: 503,
            code: "gemini_retry_exhausted".to_string(),
            purge_at: 2_000,
            subjects: vec![OWNER.to_string()],
            content_hash: CONTENT.to_string(),
            billing: None,
        },
        JobRecord::FailedTransient {
            job_id: "fingerprint-123".to_string(),
            purge_at: 2_000,
            subjects: vec![OWNER.to_string()],
            content_hash: CONTENT.to_string(),
            billing: None,
        },
    ] {
        assert_eq!(
            poll_decision(Some(&record), Some(STRANGER)),
            PollDecision::NotFound
        );
    }
}

#[test]
fn poll_member_subject_sees_every_wire_outcome() {
    assert!(matches!(
        poll_decision(Some(&running()), Some(OWNER)),
        PollDecision::Running { .. }
    ));
    assert!(matches!(
        poll_decision(Some(&completed()), Some(OWNER)),
        PollDecision::ServeCompleted { .. }
    ));
    assert_eq!(poll_decision(None, Some(OWNER)), PollDecision::NotFound);

    let mut joined = completed();
    joined.push_subject(STRANGER);
    assert!(matches!(
        poll_decision(Some(&joined), Some(STRANGER)),
        PollDecision::ServeCompleted { .. }
    ));
}

#[test]
fn content_hash_is_deterministic_and_content_sensitive() {
    let transcript = TranscriptMetadata {
        language_code: "en-US".to_string(),
        audio_duration: 1234.56,
        model_identifier: Some("model".to_string()),
        model_version: None,
        model_tree_sha256: None,
        fingerprint: "fingerprint-123".to_string(),
        updated_at: "2026-08-23T00:00:00Z".to_string(),
        state: "completed".to_string(),
        segment_count: 1,
    };
    let segments = vec![TranscriptSegment {
        id: 1,
        start: 0.0,
        end: 4.25,
        text: "hello".to_string(),
    }];

    let hash = transcript_content_hash(&transcript, &segments);
    assert_eq!(hash, transcript_content_hash(&transcript, &segments));
    assert_eq!(hash.len(), 64);

    let mut altered = segments.clone();
    altered[0].text = "hello world".to_string();
    assert_ne!(hash, transcript_content_hash(&transcript, &altered));
}

#[test]
fn lane_subjects_are_prefixed_and_collision_free() {
    assert_eq!(app_attest_subject("h"), "app-attest-key:h");
    assert_eq!(bearer_subject("h"), "bearer:h");
}

#[test]
fn alarm_decisions_heartbeat_watchdog_and_purge() {
    let running = running();
    assert_eq!(
        alarm_decision(Some(&running), true, 100 + JOB_RUNNING_DEADLINE_SECONDS - 1),
        AlarmDecision::Heartbeat
    );
    for (run_active, now) in [(false, 101), (true, 100 + JOB_RUNNING_DEADLINE_SECONDS)] {
        // The watchdog's transient-failure record keeps the subject set and
        // content hash so authorization survives the transition.
        assert_eq!(
            alarm_decision(Some(&running), run_active, now),
            AlarmDecision::FailTransient {
                record: JobRecord::FailedTransient {
                    job_id: "fingerprint-123".to_string(),
                    purge_at: now + JOB_RESULT_TTL_SECONDS,
                    subjects: vec![OWNER.to_string()],
                    content_hash: CONTENT.to_string(),
                    billing: None,
                }
            }
        );
    }

    let completed = completed();
    assert_eq!(
        alarm_decision(Some(&completed), false, 1_999),
        AlarmDecision::SchedulePurge { purge_at: 2_000 }
    );
    assert_eq!(
        alarm_decision(Some(&completed), false, 2_000),
        AlarmDecision::Purge
    );
    assert_eq!(alarm_decision(None, false, 2_000), AlarmDecision::Purge);
}

/// A watchdogged run still holds its reservation and nothing else can free
/// it — the billing state must ride into the transient-failure record
/// untouched, and the shared terminal rule must derive a release for it.
/// `terminal_billing_action` is the single home of the
/// settle-vs-release decision.
#[test]
fn watchdog_transient_failure_carries_billing_and_derives_release() {
    let billed_running = JobRecord::Running {
        job_id: "fingerprint-123".to_string(),
        started_at: 100,
        subjects: vec![OWNER.to_string()],
        content_hash: CONTENT.to_string(),
        billing: Some(JobBillingState::reserved("tan-abc123def456ghij".to_string(), 27_115)),
    };
    let AlarmDecision::FailTransient { record } = alarm_decision(Some(&billed_running), false, 101)
    else {
        panic!("expected watchdog transition");
    };
    let billing = record.billing().expect("billing carried to the terminal");
    assert_eq!(billing.billing_id, "tan-abc123def456ghij");
    assert_eq!(billing.charge_seconds, 27_115);
    assert_eq!(billing.pending, None);
    assert_eq!(billing.attempts, 0);
    assert_eq!(
        terminal_billing_action(&record),
        Some(PendingBillingAction::Release)
    );
}

/// Delivered results settle, every failure releases, and unbilled records
/// have no action — the one rule every terminalizer shares.
#[test]
fn terminal_billing_action_settles_delivery_and_releases_failures() {
    let mut billed_completed = completed();
    if let JobRecord::Completed { billing, .. } = &mut billed_completed {
        *billing = Some(JobBillingState::reserved("tan-abc123def456ghij".to_string(), 500));
    }
    assert_eq!(
        terminal_billing_action(&billed_completed),
        Some(PendingBillingAction::Settle)
    );

    let billed_failed = JobRecord::FailedUpstream {
        job_id: "fingerprint-123".to_string(),
        status: 502,
        code: "model_output_truncated".to_string(),
        purge_at: 2_000,
        subjects: vec![OWNER.to_string()],
        content_hash: CONTENT.to_string(),
        billing: Some(JobBillingState::reserved("tan-abc123def456ghij".to_string(), 500)),
    };
    assert_eq!(
        terminal_billing_action(&billed_failed),
        Some(PendingBillingAction::Release)
    );

    assert_eq!(terminal_billing_action(&completed()), None);
}

/// Terminal records with an unresolved settle/release retry before the
/// purge deadline and purge (with a final attempt) at it.
#[test]
fn alarm_retries_pending_billing_before_purge() {
    let mut record = completed();
    if let JobRecord::Completed { billing, .. } = &mut record {
        *billing = Some(JobBillingState {
            billing_id: "tan-abc123def456ghij".to_string(),
            charge_seconds: 500,
            pending: Some(PendingBillingAction::Settle),
            attempts: 1,
        });
    }
    assert_eq!(
        alarm_decision(Some(&record), false, 1_999),
        AlarmDecision::RetryBilling
    );
    // At/after the purge deadline the purge path owns the final attempt.
    assert_eq!(
        alarm_decision(Some(&record), false, 2_000),
        AlarmDecision::Purge
    );
    // Resolved billing keeps the normal purge schedule.
    if let JobRecord::Completed { billing, .. } = &mut record {
        billing.as_mut().unwrap().pending = None;
    }
    assert_eq!(
        alarm_decision(Some(&record), false, 1_999),
        AlarmDecision::SchedulePurge { purge_at: 2_000 }
    );
}

/// Deploy skew: a record written by a pre-billing worker version parses
/// with no billing state, and a billed record round-trips.
#[test]
fn job_record_billing_serde_covers_skew_and_round_trip() {
    let legacy: JobRecord = serde_json::from_str(
        r#"{"state":"completed","job_id":"fingerprint-123","result_json":"r","purge_at":2000}"#,
    )
    .expect("pre-billing record parses");
    assert!(legacy.billing().is_none());

    let mut billed = completed();
    if let JobRecord::Completed { billing, .. } = &mut billed {
        *billing = Some(JobBillingState {
            billing_id: "tan-abc123def456ghij".to_string(),
            charge_seconds: 500,
            pending: Some(PendingBillingAction::Release),
            attempts: 2,
        });
    }
    let encoded = serde_json::to_string(&billed).expect("billed record serializes");
    let decoded: JobRecord = serde_json::from_str(&encoded).expect("billed record parses");
    assert_eq!(decoded, billed);
}

#[test]
fn job_ids_are_url_safe_and_namespaced() {
    for valid in ["12345678", "fingerprint-123._", &"a".repeat(128)] {
        assert!(valid_job_id(valid));
    }
    for invalid in [
        "1234567",
        "bad/id00",
        "bad id00",
        "ümlaut00",
        &"a".repeat(129),
    ] {
        assert!(!valid_job_id(invalid));
    }
    assert_eq!(
        job_object_name("fingerprint-123"),
        "transcript-analysis:v1:job:fingerprint-123"
    );
}

fn completed_response(usage: Option<GeminiUsage>) -> TranscriptAnalysisResponse {
    TranscriptAnalysisResponse {
        schema_version: 1,
        request_id: "req-123".to_string(),
        model: "gemini-3.5-flash".to_string(),
        policy: "transcript_analysis_v2".to_string(),
        chapters: vec![ValidatedChapter {
            title: "SECRET-CHAPTER-TITLE".to_string(),
            start_segment_id: 0,
            end_segment_id: 10,
            start_time: 0.0,
            end_time: 60.0,
            confidence: 0.9,
        }],
        summary: Some(ValidatedSummary {
            summary: "SECRET-SUMMARY-TEXT".to_string(),
            one_line_description: "SECRET-ONE-LINE".to_string(),
            claims: vec![
                ValidatedClaim {
                    text: "SECRET-CLAIM-ONE".to_string(),
                    evidence_segment_id: 3,
                },
                ValidatedClaim {
                    text: "SECRET-CLAIM-TWO".to_string(),
                    evidence_segment_id: 7,
                },
            ],
        }),
        warnings: vec!["invalid_model_output_retried_high:chapter_count_cap".to_string()],
        usage,
    }
}

#[test]
fn completion_log_line_is_content_free_json_with_usage() {
    let response = completed_response(Some(GeminiUsage {
        prompt_token_count: 8_445,
        candidates_token_count: 643,
        thoughts_token_count: 2_489,
        total_token_count: 11_577,
    }));
    let line = completion_log_line(&response, 1_450, 746, 2, 26_200);
    let parsed: serde_json::Value = serde_json::from_str(&line).expect("log line is JSON");
    assert_eq!(parsed["event"], "transcript_analysis_completed");
    assert_eq!(parsed["request_id"], "req-123");
    assert_eq!(parsed["model"], "gemini-3.5-flash");
    assert_eq!(parsed["segments"], 1_450);
    assert_eq!(parsed["model_units"], 746);
    assert_eq!(parsed["attempts"], 2);
    assert_eq!(parsed["elapsed_ms"], 26_200);
    assert_eq!(parsed["chapters"], 1);
    assert_eq!(parsed["claims"], 2);
    assert_eq!(parsed["prompt_tokens"], 8_445);
    assert_eq!(parsed["candidates_tokens"], 643);
    assert_eq!(parsed["thoughts_tokens"], 2_489);
    assert_eq!(parsed["total_tokens"], 11_577);
    // Fixed warning codes are the only string passthrough the line allows.
    assert_eq!(
        parsed["warnings"][0],
        "invalid_model_output_retried_high:chapter_count_cap"
    );
    for secret in [
        "SECRET-CHAPTER-TITLE",
        "SECRET-SUMMARY-TEXT",
        "SECRET-ONE-LINE",
        "SECRET-CLAIM-ONE",
        "SECRET-CLAIM-TWO",
    ] {
        assert!(!line.contains(secret), "log line leaked content: {secret}");
    }
}

#[test]
fn completion_log_line_without_usage_keeps_token_fields_null() {
    let line = completion_log_line(&completed_response(None), 203, 203, 1, 21_700);
    let parsed: serde_json::Value = serde_json::from_str(&line).expect("log line is JSON");
    assert_eq!(parsed["segments"], 203);
    assert_eq!(parsed["model_units"], 203);
    assert!(parsed["prompt_tokens"].is_null());
    assert!(parsed["candidates_tokens"].is_null());
    assert!(parsed["thoughts_tokens"].is_null());
    assert!(parsed["total_tokens"].is_null());
}
