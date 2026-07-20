use opencast_ad_analysis_worker::job::{
    alarm_decision, job_object_name, poll_decision, submit_decision, valid_job_id, AlarmDecision,
    JobRecord, PollDecision, SubmitDecision, JOB_RESULT_TTL_SECONDS, JOB_RUNNING_DEADLINE_SECONDS,
};

#[test]
fn job_record_serde_round_trips_every_state() {
    let records = [
        JobRecord::Running {
            job_id: "fingerprint-123".to_string(),
            started_at: 100,
        },
        JobRecord::Completed {
            job_id: "fingerprint-123".to_string(),
            result_json: r#"{"schema_version":1}"#.to_string(),
            purge_at: 2_000,
        },
        JobRecord::FailedUpstream {
            job_id: "fingerprint-123".to_string(),
            status: 503,
            code: "gemini_retry_exhausted".to_string(),
            purge_at: 2_000,
        },
        JobRecord::FailedTransient {
            job_id: "fingerprint-123".to_string(),
            purge_at: 2_000,
        },
    ];

    for record in records {
        let encoded = serde_json::to_string(&record).expect("record serializes");
        assert!(encoded.contains(r#""state":"#));
        assert!(!encoded.contains("transcript"));
        let decoded: JobRecord = serde_json::from_str(&encoded).expect("record deserializes");
        assert_eq!(decoded, record);
    }
}

#[test]
fn submit_decisions_attach_serve_or_restart() {
    let running = JobRecord::Running {
        job_id: "fingerprint-123".to_string(),
        started_at: 100,
    };
    assert_eq!(
        submit_decision(Some(&running)),
        SubmitDecision::Attach {
            job_id: "fingerprint-123".to_string()
        }
    );

    let completed = JobRecord::Completed {
        job_id: "fingerprint-123".to_string(),
        result_json: "result".to_string(),
        purge_at: 2_000,
    };
    assert_eq!(
        submit_decision(Some(&completed)),
        SubmitDecision::ServeCompleted {
            job_id: "fingerprint-123".to_string(),
            result_json: "result".to_string()
        }
    );

    let failed = JobRecord::FailedTransient {
        job_id: "fingerprint-123".to_string(),
        purge_at: 2_000,
    };
    assert_eq!(submit_decision(Some(&failed)), SubmitDecision::Start);
    assert_eq!(submit_decision(None), SubmitDecision::Start);
}

#[test]
fn poll_decisions_cover_every_wire_outcome() {
    assert_eq!(poll_decision(None), PollDecision::NotFound);
    assert!(matches!(
        poll_decision(Some(&JobRecord::Running {
            job_id: "fingerprint-123".to_string(),
            started_at: 100,
        })),
        PollDecision::Running { .. }
    ));
    assert!(matches!(
        poll_decision(Some(&JobRecord::Completed {
            job_id: "fingerprint-123".to_string(),
            result_json: "result".to_string(),
            purge_at: 2_000,
        })),
        PollDecision::ServeCompleted { .. }
    ));
    assert_eq!(
        poll_decision(Some(&JobRecord::FailedUpstream {
            job_id: "fingerprint-123".to_string(),
            status: 503,
            code: "gemini_retry_exhausted".to_string(),
            purge_at: 2_000,
        })),
        PollDecision::ServeFailedUpstream {
            status: 503,
            code: "gemini_retry_exhausted".to_string()
        }
    );
    assert_eq!(
        poll_decision(Some(&JobRecord::FailedTransient {
            job_id: "fingerprint-123".to_string(),
            purge_at: 2_000,
        })),
        PollDecision::ServeFailedTransient
    );
}

#[test]
fn alarm_decisions_heartbeat_watchdog_and_purge() {
    let running = JobRecord::Running {
        job_id: "fingerprint-123".to_string(),
        started_at: 100,
    };
    assert_eq!(
        alarm_decision(Some(&running), true, 100 + JOB_RUNNING_DEADLINE_SECONDS - 1),
        AlarmDecision::Heartbeat
    );
    for (run_active, now) in [(false, 101), (true, 100 + JOB_RUNNING_DEADLINE_SECONDS)] {
        assert_eq!(
            alarm_decision(Some(&running), run_active, now),
            AlarmDecision::FailTransient {
                record: JobRecord::FailedTransient {
                    job_id: "fingerprint-123".to_string(),
                    purge_at: now + JOB_RESULT_TTL_SECONDS,
                }
            }
        );
    }

    let completed = JobRecord::Completed {
        job_id: "fingerprint-123".to_string(),
        result_json: "result".to_string(),
        purge_at: 2_000,
    };
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
