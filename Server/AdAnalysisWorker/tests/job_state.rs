use std::cell::Cell;
use std::future::Future;

use opencast_ad_analysis_worker::job::{
    alarm_decision, app_attest_subject, bearer_subject, job_object_name, poll_decision,
    submit_decision, transcript_content_hash, transcription_account_subject, valid_job_id,
    ActiveWindow, AlarmDecision, JobRecord, PollDecision, SubmitDecision, ERROR_ADMISSION_BUSY,
    JOB_RESULT_TTL_SECONDS, JOB_RUNNING_DEADLINE_SECONDS, SUBMIT_ADMISSION_MAX_WAITS,
    SUBMIT_ADMISSION_WAIT_MILLIS,
};
use opencast_ad_analysis_worker::types::{TranscriptMetadata, TranscriptSegment};

const OWNER: &str = "app-attest-key:owner-hash";
const STRANGER: &str = "app-attest-key:stranger-hash";
const INTERNAL: &str = "transcription-account:rtw-hash";
const CONTENT: &str = "content-hash-aaaa";
const OTHER_CONTENT: &str = "content-hash-bbbb";

fn running() -> JobRecord {
    JobRecord::Running {
        job_id: "fingerprint-123".to_string(),
        started_at: 100,
        subjects: vec![OWNER.to_string()],
        content_hash: CONTENT.to_string(),
    }
}

fn completed() -> JobRecord {
    JobRecord::Completed {
        job_id: "fingerprint-123".to_string(),
        result_json: "result".to_string(),
        purge_at: 2_000,
        subjects: vec![OWNER.to_string()],
        content_hash: CONTENT.to_string(),
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
        },
        JobRecord::FailedTransient {
            job_id: "fingerprint-123".to_string(),
            purge_at: 2_000,
            subjects: vec![OWNER.to_string()],
            content_hash: CONTENT.to_string(),
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

/// Records persisted before the owner-binding scheme carry neither subjects
/// nor a content hash; they must still deserialize and behave legacy-open.
#[test]
fn pre_scheme_records_deserialize_and_stay_open_until_purge() {
    let legacy_running: JobRecord =
        serde_json::from_str(r#"{"state":"running","job_id":"fingerprint-123","started_at":100}"#)
            .expect("pre-scheme record deserializes");
    assert_eq!(legacy_running.subjects(), &[] as &[String]);
    assert_eq!(legacy_running.content_hash(), "");

    // Any subject may poll or attach while the legacy record lives.
    assert!(matches!(
        poll_decision(Some(&legacy_running), Some(STRANGER)),
        PollDecision::Running { .. }
    ));
    assert!(matches!(
        submit_decision(Some(&legacy_running), STRANGER, OTHER_CONTENT, false),
        SubmitDecision::Attach { join: false, .. }
    ));
}

#[test]
fn submit_same_subject_reattaches_without_content_check() {
    assert_eq!(
        submit_decision(Some(&running()), OWNER, OTHER_CONTENT, false),
        SubmitDecision::Attach {
            job_id: "fingerprint-123".to_string(),
            join: false,
        }
    );
    assert!(matches!(
        submit_decision(Some(&completed()), OWNER, OTHER_CONTENT, false),
        SubmitDecision::ServeCompleted { join: false, .. }
    ));
}

/// The cost-sharing feature: a new subject that possesses the exact stored
/// content joins the job (and the join must be persisted).
#[test]
fn submit_content_matched_new_subject_joins() {
    assert_eq!(
        submit_decision(Some(&running()), STRANGER, CONTENT, false),
        SubmitDecision::Attach {
            job_id: "fingerprint-123".to_string(),
            join: true,
        }
    );
    assert!(matches!(
        submit_decision(Some(&completed()), STRANGER, CONTENT, false),
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

/// Blind attach / poisoning: same fingerprint, different content, public
/// caller — denied.
#[test]
fn submit_content_mismatch_from_public_subject_is_denied() {
    assert_eq!(
        submit_decision(Some(&running()), STRANGER, OTHER_CONTENT, false),
        SubmitDecision::DenyContentMismatch
    );
    assert_eq!(
        submit_decision(Some(&completed()), STRANGER, OTHER_CONTENT, false),
        SubmitDecision::DenyContentMismatch
    );
}

/// A name-squatter must not be able to deny service to the trusted internal
/// lane: an internal submit over mismatched content replaces the job.
#[test]
fn internal_submit_replaces_squatted_name() {
    let squatted = JobRecord::Running {
        job_id: "fingerprint-123".to_string(),
        started_at: 100,
        subjects: vec![STRANGER.to_string()],
        content_hash: OTHER_CONTENT.to_string(),
    };
    assert_eq!(
        submit_decision(Some(&squatted), INTERNAL, CONTENT, true),
        SubmitDecision::Replace
    );

    // Internal resubmits of the same content attach like anyone else.
    assert_eq!(
        submit_decision(Some(&running()), INTERNAL, CONTENT, true),
        SubmitDecision::Attach {
            job_id: "fingerprint-123".to_string(),
            join: true,
        }
    );
}

#[test]
fn submit_failed_records_always_restart() {
    let failed = JobRecord::FailedTransient {
        job_id: "fingerprint-123".to_string(),
        purge_at: 2_000,
        subjects: vec![OWNER.to_string()],
        content_hash: CONTENT.to_string(),
    };
    assert_eq!(
        submit_decision(Some(&failed), STRANGER, OTHER_CONTENT, false),
        SubmitDecision::Start
    );
    assert_eq!(
        submit_decision(None, OWNER, CONTENT, false),
        SubmitDecision::Start
    );
}

/// The chained-name exposure: a public subject that computed the DO name
/// (sha256("ad-analysis|{rtw_job_id}")) but is not in the subject set gets
/// the same NotFound a nonexistent job produces — polls, results, and the
/// purge-on-serve failure paths are all unreachable.
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
        },
        JobRecord::FailedTransient {
            job_id: "fingerprint-123".to_string(),
            purge_at: 2_000,
            subjects: vec![OWNER.to_string()],
            content_hash: CONTENT.to_string(),
        },
    ] {
        assert_eq!(
            poll_decision(Some(&record), Some(STRANGER)),
            PollDecision::NotFound
        );
    }
}

#[test]
fn poll_member_subject_and_internal_lane_see_every_wire_outcome() {
    // Same-subject poll works; the host-gated internal lane (None) polls
    // anything — RTW's chained flow is unaffected by the binding.
    for subject in [Some(OWNER), None] {
        assert!(matches!(
            poll_decision(Some(&running()), subject),
            PollDecision::Running { .. }
        ));
        assert!(matches!(
            poll_decision(Some(&completed()), subject),
            PollDecision::ServeCompleted { .. }
        ));
    }
    assert_eq!(poll_decision(None, Some(OWNER)), PollDecision::NotFound);
    assert_eq!(poll_decision(None, None), PollDecision::NotFound);

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
        updated_at: "2026-08-03T00:00:00Z".to_string(),
        state: "complete".to_string(),
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
    assert_eq!(
        transcription_account_subject("h"),
        "transcription-account:h"
    );
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
        "ad-analysis:v1:job:fingerprint-123"
    );
}

/// Audit §28: the admission window is an RAII guard, so a submit future
/// dropped mid-admission (client disconnect) releases the latch instead of
/// wedging every later submit; the wait on a held window is bounded.
#[test]
fn admission_window_releases_on_every_exit_path() {
    let flag = Cell::new(false);

    let window = ActiveWindow::acquire(&flag).expect("free window acquires");
    assert!(flag.get());
    assert!(
        ActiveWindow::acquire(&flag).is_none(),
        "a held window refuses a second acquire"
    );
    drop(window);
    assert!(!flag.get(), "drop releases the window");

    // A dropped future drops its locals: the guard held inside a pending
    // async block releases when the future is discarded before completion.
    let pending = async {
        let _window = ActiveWindow::acquire(&flag).expect("free window acquires");
        std::future::pending::<()>().await;
    };
    let mut pending = Box::pin(pending);
    let waker = std::task::Waker::noop();
    let mut context = std::task::Context::from_waker(waker);
    assert!(pending.as_mut().poll(&mut context).is_pending());
    assert!(flag.get(), "the parked future holds the window");
    drop(pending);
    assert!(
        !flag.get(),
        "dropping the parked future releases the window"
    );
    assert!(ActiveWindow::acquire(&flag).is_some());

    // Bounded wait: 500 × 10 ms = 5 s before the 503.
    assert_eq!(
        u64::from(SUBMIT_ADMISSION_MAX_WAITS) * SUBMIT_ADMISSION_WAIT_MILLIS,
        5_000
    );
    assert_eq!(ERROR_ADMISSION_BUSY, "admission_busy");
}
