use opencast_ad_analysis_worker::{
    accounting::{self, Operation, Record, Request},
    types::GeminiUsage,
    usage::UsageLimitProfile,
    validation::DailyUsage,
};

fn request(operation: Operation) -> Request {
    Request {
        run_id: "unique-run-123".into(),
        subject: "caller-123".into(),
        profile: UsageLimitProfile::AppAttestKey,
        day: 1,
        legacy_caller: DailyUsage::default(),
        operation,
    }
}
fn apply(record: Option<&Record>, operation: Operation, now: u64) -> Record {
    let totals = record.map(Record::charged).unwrap_or_default();
    accounting::apply(record, &request(operation), totals.clone(), totals, now).unwrap()
}
fn admitted() -> Record {
    apply(
        None,
        Operation::Admit {
            execution_tokens: 30_000,
            expires_at: 86_999,
        },
        86_400,
    )
}
fn dispatched(mut record: Record, id: u8) -> Record {
    record = apply(
        Some(&record),
        Operation::Reserve {
            attempt: id,
            input_tokens: 1000,
        },
        86_401,
    );
    apply(Some(&record), Operation::Dispatch { attempt: id }, 86_402)
}

#[test]
fn no_repair_multiple_windows_and_repairs_count_one_job() {
    for attempts in [1, 2, 3, 9, 18] {
        let mut record = admitted();
        for id in 0..attempts {
            record = dispatched(record, id);
        }
        let record = apply(Some(&record), Operation::Finish, 86_450);
        assert_eq!(
            record.charged(),
            DailyUsage {
                request_count: 1,
                estimated_input_tokens: u64::from(attempts) * 1000
            }
        );
    }
}
#[test]
fn unused_hold_is_released_and_dispatched_unknown_is_retained() {
    let record = dispatched(admitted(), 0);
    let record = apply(
        Some(&record),
        Operation::Reserve {
            attempt: 2,
            input_tokens: 2000,
        },
        86_403,
    );
    let record = apply(Some(&record), Operation::Finish, 86_404);
    let summary = record.summary();
    assert_eq!(summary.request_count, 1);
    assert_eq!(summary.dispatched_input_tokens, 1000);
    assert_eq!(summary.released_input_tokens, 2000);
    assert_eq!(summary.unknown_attempts, 1);
    assert_eq!(summary.reported_usage, None);
    assert_eq!(apply(Some(&record), Operation::Finish, 86_405), record);
}
#[test]
fn receipt_is_idempotent_and_output_tokens_never_reduce_input_charge() {
    let record = dispatched(admitted(), 0);
    let receipt = Operation::Receipt {
        attempt: 0,
        usage: GeminiUsage {
            prompt_token_count: 120,
            candidates_token_count: 40,
            thoughts_token_count: 10,
            total_token_count: 170,
        },
    };
    let record = apply(Some(&record), receipt.clone(), 86_403);
    let record = apply(Some(&record), receipt, 86_404);
    assert_eq!(record.charged().estimated_input_tokens, 1000);
    assert_eq!(record.summary().unknown_attempts, 0);
    assert_eq!(
        record.summary().reported_usage.unwrap().total_token_count,
        170
    );
}
#[test]
fn global_denial_does_not_admit_or_debit_the_caller() {
    let req = request(Operation::Admit {
        execution_tokens: 30_000,
        expires_at: 86_999,
    });
    let caller = DailyUsage::default();
    assert_eq!(
        accounting::apply(
            None,
            &req,
            caller.clone(),
            DailyUsage {
                request_count: 300,
                estimated_input_tokens: 0
            },
            86_400
        ),
        Err("global_capacity_exhausted")
    );
    assert_eq!(caller, DailyUsage::default());
    let record = admitted();
    let req = request(Operation::Reserve {
        attempt: 2,
        input_tokens: 1000,
    });
    assert_eq!(
        accounting::apply(
            Some(&record),
            &req,
            record.charged(),
            DailyUsage {
                request_count: 1,
                estimated_input_tokens: 8_000_000
            },
            86_400
        ),
        Err("global_capacity_exhausted")
    );
    assert!(record.attempts.is_empty());
}
#[test]
fn duplicate_admission_dispatch_and_settlement_cannot_create_allowance() {
    let record = dispatched(admitted(), 0);
    let duplicate = apply(
        Some(&record),
        Operation::Admit {
            execution_tokens: 30_000,
            expires_at: 86_999,
        },
        86_500,
    );
    assert_eq!(duplicate, record);
    let req = request(Operation::Dispatch { attempt: 0 });
    assert_eq!(
        accounting::apply(
            Some(&record),
            &req,
            record.charged(),
            record.charged(),
            86_500
        ),
        Err("attempt_already_dispatched")
    );
    let mut wrong = request(Operation::Finish);
    wrong.subject = "other-caller".into();
    assert_eq!(
        accounting::apply(
            Some(&record),
            &wrong,
            record.charged(),
            record.charged(),
            86_500
        ),
        Err("accounting_identity_mismatch")
    );
}
#[test]
fn crash_before_dispatch_releases_job_and_all_tokens() {
    let mut record = apply(
        Some(&admitted()),
        Operation::Reserve {
            attempt: 0,
            input_tokens: 1000,
        },
        86_401,
    );
    record.finish();
    assert_eq!(record.charged(), DailyUsage::default());
    assert_eq!(record.summary().released_input_tokens, 1000);
}
#[test]
fn day_rollover_keeps_the_original_bucket_and_disallows_old_day_new_admission() {
    let mut req = request(Operation::Admit {
        execution_tokens: 30_000,
        expires_at: 173_100,
    });
    let record = accounting::apply(
        None,
        &req,
        DailyUsage::default(),
        DailyUsage::default(),
        172_790,
    )
    .unwrap();
    req.operation = Operation::Reserve {
        attempt: 0,
        input_tokens: 1000,
    };
    let record = accounting::apply(
        Some(&record),
        &req,
        record.charged(),
        record.charged(),
        172_801,
    )
    .unwrap();
    assert_eq!(record.day, 1);
    req.operation = Operation::Admit {
        execution_tokens: 30_000,
        expires_at: 173_100,
    };
    assert_eq!(
        accounting::apply(
            None,
            &req,
            DailyUsage::default(),
            DailyUsage::default(),
            172_801
        ),
        Err("invalid_execution_allowance")
    );
}
