use opencast_transcript_analysis_worker::gemini::{
    parse_error_envelope, parse_generate_content_response, GeminiErrorBody, GeminiParseError,
};
use opencast_transcript_analysis_worker::retry::{
    classify_http_status, parse_retry_after_seconds, RetryDecision,
};

fn model_output_json() -> String {
    serde_json::json!({
        "chapters": [
            {"title": "Opening", "start_segment_id": 0, "end_segment_id": 1, "confidence": 0.8},
        ],
        "summary": {
            "summary": "A short episode.",
            "one_line_description": "Short",
            "claims": [{"text": "It is short", "evidence_segment_id": 0}],
        },
    })
    .to_string()
}

fn wrap_candidate(text: &str, finish_reason: &str) -> String {
    serde_json::json!({
        "candidates": [
            {"content": {"parts": [{"text": text}]}, "finishReason": finish_reason}
        ],
        "usageMetadata": {
            "promptTokenCount": 100,
            "candidatesTokenCount": 20,
            "thoughtsTokenCount": 3000,
            "totalTokenCount": 3120
        }
    })
    .to_string()
}

#[test]
fn parses_gemini_text_json_and_usage_with_thoughts() {
    let parsed = parse_generate_content_response(&wrap_candidate(&model_output_json(), "STOP"));

    let output = parsed.output.expect("valid response has output");
    assert_eq!(output.chapters.len(), 1);
    assert_eq!(output.chapters[0].title, "Opening");
    assert_eq!(output.summary.claims.len(), 1);
    let usage = parsed.usage.expect("usage present");
    // Thoughts are recorded separately for cost instrumentation (billed
    // output = candidates + thoughts).
    assert_eq!(usage.thoughts_token_count, 3_000);
    assert_eq!(usage.total_token_count, 3_120);
    assert!(parsed.warnings.is_empty());
    assert!(parsed.failure.is_none());
}

#[test]
fn usage_totals_cover_thinking_tokens_when_total_omits_them() {
    let body = r#"{
      "candidates": [
        {"content": {"parts": [{"text": "irrelevant"}]}, "finishReason": "STOP"}
      ],
      "usageMetadata": {
        "promptTokenCount": 100,
        "candidatesTokenCount": 20,
        "thoughtsTokenCount": 1700,
        "totalTokenCount": 120
      }
    }"#;

    let parsed = parse_generate_content_response(body);

    assert_eq!(parsed.usage.unwrap().total_token_count, 1_820);
}

#[test]
fn parse_failures_distinguish_malformed_response_missing_text_and_model_json() {
    let parsed = parse_generate_content_response("not-json");
    assert!(parsed.output.is_none());
    assert_eq!(parsed.failure, Some(GeminiParseError::MalformedResponse));

    let parsed = parse_generate_content_response(r#"{"candidates":[]}"#);
    assert!(parsed.output.is_none());
    assert_eq!(parsed.failure, Some(GeminiParseError::MissingCandidateText));

    let parsed = parse_generate_content_response(
        r#"{"candidates":[{"content":{"parts":[{"text":"   "}]},"finishReason":"STOP"}]}"#,
    );
    assert!(parsed.output.is_none());
    assert_eq!(parsed.failure, Some(GeminiParseError::MissingCandidateText));

    let parsed = parse_generate_content_response(
        r#"{"candidates":[{"content":{"parts":[{"text":"{\"chapters\":"}]},"finishReason":"STOP"}]}"#,
    );
    assert!(parsed.output.is_none());
    assert_eq!(parsed.failure, Some(GeminiParseError::MalformedModelJson));

    // A response missing required model-output fields is malformed, never
    // partial output.
    let parsed = parse_generate_content_response(
        r#"{"candidates":[{"content":{"parts":[{"text":"{\"chapters\":[]}"}]},"finishReason":"STOP"}]}"#,
    );
    assert!(parsed.output.is_none());
    assert_eq!(parsed.failure, Some(GeminiParseError::MalformedModelJson));
}

/// MAX_TOKENS is a hard parse failure here — unlike the ad-analysis
/// template, which tolerated a non-STOP finish when the JSON happened to
/// parse. A truncated schema-constrained response can be a valid JSON
/// prefix, and evaluation measured truncation as transient (retry fixes it), so
/// the text is never trusted.
#[test]
fn max_tokens_is_a_failure_even_when_the_json_parses() {
    let parsed =
        parse_generate_content_response(&wrap_candidate(&model_output_json(), "MAX_TOKENS"));

    assert!(parsed.output.is_none());
    assert_eq!(parsed.failure, Some(GeminiParseError::MaxTokensTruncated));
    assert_eq!(
        GeminiParseError::MaxTokensTruncated.code(),
        "max_tokens_truncated"
    );
    assert_eq!(parsed.warnings, vec!["gemini_finish_reason:MAX_TOKENS"]);
    // The burned usage still surfaces for cost instrumentation.
    assert_eq!(parsed.usage.unwrap().total_token_count, 3_120);
}

#[test]
fn safety_finish_is_a_non_stop_failure() {
    let parsed = parse_generate_content_response(&wrap_candidate(&model_output_json(), "SAFETY"));

    assert!(parsed.output.is_none());
    assert_eq!(parsed.failure, Some(GeminiParseError::NonStopFinishReason));
    assert_eq!(parsed.warnings, vec!["gemini_finish_reason:SAFETY"]);
}

#[test]
fn parser_combines_text_parts() {
    let body = r#"{
      "candidates": [
        {
          "content": {
            "parts": [
              {"text": "{\"chapters\":[{\"title\":\"T\",\"start_segment_id\":0,\"end_segment_id\":0,\"confidence\":0.5}],"},
              {"text": "\"summary\":{\"summary\":\"s\",\"one_line_description\":\"o\",\"claims\":[{\"text\":\"c\",\"evidence_segment_id\":0}]}}"}
            ]
          },
          "finishReason": "STOP"
        }
      ]
    }"#;

    let parsed = parse_generate_content_response(body);

    let output = parsed.output.expect("valid combined JSON has output");
    assert_eq!(output.chapters.len(), 1);
    assert!(parsed.usage.is_none());
}

#[test]
fn parses_gemini_error_envelope_when_present() {
    let body = r#"{
      "error": {
        "code": 429,
        "message": "Resource exhausted, check billing.",
        "status": "RESOURCE_EXHAUSTED"
      }
    }"#;

    let error = parse_error_envelope(body).expect("error envelope should parse");

    assert_eq!(error.code, Some(429));
    assert_eq!(error.status.as_deref(), Some("RESOURCE_EXHAUSTED"));
    assert!(error.message.contains("billing"));
    assert!(parse_error_envelope(r#"{"message":"not the Gemini shape"}"#).is_none());
}

#[test]
fn retry_classification_handles_transient_and_quota_statuses() {
    assert_eq!(
        classify_http_status(503, Some("7"), None),
        RetryDecision::Retry {
            retry_after_seconds: Some(7)
        }
    );

    let quota = GeminiErrorBody {
        code: Some(429),
        message: "You exceeded your current quota. Check billing.".to_string(),
        status: Some("RESOURCE_EXHAUSTED".to_string()),
    };
    assert_eq!(
        classify_http_status(429, None, Some(&quota)),
        RetryDecision::HardQuota
    );

    let transient = GeminiErrorBody {
        code: Some(429),
        message: "Too many requests, try again later.".to_string(),
        status: Some("RESOURCE_EXHAUSTED".to_string()),
    };
    assert!(classify_http_status(429, None, Some(&transient)).is_retry());
    assert_eq!(
        classify_http_status(500, None, None),
        RetryDecision::Retry {
            retry_after_seconds: None
        }
    );
    assert_eq!(
        classify_http_status(504, Some("999"), None),
        RetryDecision::Retry {
            retry_after_seconds: Some(30)
        }
    );
    assert_eq!(
        classify_http_status(400, None, None),
        RetryDecision::DoNotRetry
    );
}

#[test]
fn retry_after_parses_only_numeric_seconds_and_caps_delay() {
    assert_eq!(parse_retry_after_seconds(" 12 "), Some(12));
    assert_eq!(parse_retry_after_seconds("999"), Some(30));
    assert_eq!(
        parse_retry_after_seconds("Wed, 01 Jul 2026 00:00:00 GMT"),
        None
    );
    assert_eq!(parse_retry_after_seconds("soon"), None);
    assert_eq!(parse_retry_after_seconds("-1"), None);
}

// --- Ladder math ------------------------------------------------------------

use opencast_transcript_analysis_worker::job::JOB_RUNNING_DEADLINE_SECONDS;
use opencast_transcript_analysis_worker::retry::{
    backoff_seconds, escalation_worst_case_seconds, run_failure_error, AttemptFailure,
    BudgetExhausted, LadderConfig, LadderStep, RunBudget, TransportFailure, TransportLadder,
    ANALYSIS_BUDGET_FLOOR_SECONDS, ANALYSIS_RUN_BUDGET_SECONDS, GEMINI_CALL_TIMEOUT_HIGH_SECONDS,
    GEMINI_CALL_TIMEOUT_MEDIUM_SECONDS, MAX_RETRY_DELAY_SECONDS, MAX_TIMEOUT_RESENDS,
    TERMINAL_WRITE_MARGIN_SECONDS,
};
use opencast_transcript_analysis_worker::types::UpstreamError;

const START_MS: u64 = 1_700_000_000_000;
/// The pinned outer/inner attempt counts (`analysis.rs`), restated here so
/// the simulations below stay honest without reaching into the wasm module.
const ANALYSIS_ATTEMPTS: usize = 3;
const TRANSPORT_TRIES: usize = 5;

/// A synthetic clock that spends ladder time the way the worker would.
struct Clock {
    now_ms: u64,
    config: LadderConfig,
}

impl Clock {
    fn new(config: LadderConfig) -> Self {
        Self {
            now_ms: START_MS,
            config,
        }
    }

    fn elapsed_seconds(&self) -> u64 {
        (self.now_ms - START_MS) / self.config.millis_per_second
    }

    fn spend(&mut self, duration: std::time::Duration) {
        self.now_ms += u64::try_from(duration.as_millis()).unwrap();
    }
}

/// The caps are sized so a first-level call can time out, be resent, time
/// out again, and the escalated high call still gets its whole cap; the
/// budget plus the terminal-write margin sits inside the job watchdog.
#[test]
fn ladder_worst_case_fits_the_job_deadline() {
    assert_eq!(GEMINI_CALL_TIMEOUT_MEDIUM_SECONDS, 120);
    assert_eq!(GEMINI_CALL_TIMEOUT_HIGH_SECONDS, 300);
    assert_eq!(ANALYSIS_RUN_BUDGET_SECONDS, 540);
    assert_eq!(ANALYSIS_BUDGET_FLOOR_SECONDS, 30);
    assert_eq!(MAX_TIMEOUT_RESENDS, 1);
    assert_eq!(MAX_RETRY_DELAY_SECONDS, 30);
    assert_eq!(TERMINAL_WRITE_MARGIN_SECONDS, 60);

    let production = LadderConfig::production();
    assert!(
        escalation_worst_case_seconds(&production) <= ANALYSIS_RUN_BUDGET_SECONDS,
        "2 x medium + high = {} s exceeds the {} s budget",
        escalation_worst_case_seconds(&production),
        ANALYSIS_RUN_BUDGET_SECONDS
    );
    assert!(
        production.high_call_timeout_seconds + production.floor_seconds
            <= production.run_budget_seconds,
        "a high call plus the floor must fit the budget"
    );
    assert!(
        ANALYSIS_RUN_BUDGET_SECONDS + TERMINAL_WRITE_MARGIN_SECONDS
            <= JOB_RUNNING_DEADLINE_SECONDS as u64,
        "budget {} s + margin {} s exceeds the {} s job deadline",
        ANALYSIS_RUN_BUDGET_SECONDS,
        TERMINAL_WRITE_MARGIN_SECONDS,
        JOB_RUNNING_DEADLINE_SECONDS
    );
    for attempt in 1..=TRANSPORT_TRIES {
        assert!(backoff_seconds(attempt) <= MAX_RETRY_DELAY_SECONDS);
    }
    assert_eq!(
        (1..=4).map(backoff_seconds).collect::<Vec<_>>(),
        vec![2, 4, 8, 16]
    );
}

/// The complete timeout ladder on the real clock: every send times out,
/// every timeout is resent once. The escalated high call gets its full
/// cap, the run never leaves the budget, and the budget (not the attempt
/// count) is what ends it.
#[test]
fn complete_timeout_ladder_fits_the_budget_and_gives_high_its_cap() {
    let config = LadderConfig::production();
    let budget = RunBudget::start(config, START_MS);
    let mut clock = Clock::new(config);
    let mut call_deadlines = Vec::new();
    let mut budget_ended_it = false;

    'attempts: for attempt in 0..ANALYSIS_ATTEMPTS {
        let level = if attempt == 0 { "medium" } else { "high" };
        if budget.call_timeout(level, clock.now_ms).is_err() {
            budget_ended_it = true;
            break;
        }
        let mut ladder = TransportLadder::new(TRANSPORT_TRIES, config.max_timeout_resends);
        loop {
            let Ok(timeout) = budget.call_timeout(level, clock.now_ms) else {
                budget_ended_it = true;
                break 'attempts;
            };
            call_deadlines.push((level, timeout.as_secs()));
            clock.spend(timeout);
            assert!(clock.elapsed_seconds() <= ANALYSIS_RUN_BUDGET_SECONDS);
            match ladder.next_after(TransportFailure::Timeout) {
                LadderStep::Resend { delay_seconds } => assert_eq!(delay_seconds, 0),
                LadderStep::GiveUp { delay_seconds } => {
                    // An aborted request leaves nothing to wait for at the
                    // attempt boundary either.
                    assert_eq!(delay_seconds, 0);
                    break;
                }
            }
        }
    }

    assert_eq!(
        call_deadlines,
        vec![("medium", 120), ("medium", 120), ("high", 300)]
    );
    assert!(budget_ended_it);
    assert_eq!(clock.elapsed_seconds(), ANALYSIS_RUN_BUDGET_SECONDS);
    assert_eq!(
        budget.call_timeout("high", clock.now_ms),
        Err(BudgetExhausted)
    );
}

/// Three attempts of five fast failures each, every gap waiting the longest
/// honoured `Retry-After` — including the pause the spent ladder's last
/// failure asks for, honoured across the attempt boundary — still fit: no
/// backoff is refused and the run ends on the attempt count with budget to
/// spare.
#[test]
fn complete_fast_failure_ladder_fits_the_budget() {
    let config = LadderConfig::production();
    let budget = RunBudget::start(config, START_MS);
    let mut clock = Clock::new(config);
    let mut sends = 0;
    let mut boundary_delays = 0;

    for attempt in 0..ANALYSIS_ATTEMPTS {
        let level = if attempt == 0 { "medium" } else { "high" };
        let is_last = attempt + 1 == ANALYSIS_ATTEMPTS;
        assert!(budget.call_timeout(level, clock.now_ms).is_ok());
        let mut ladder = TransportLadder::new(TRANSPORT_TRIES, config.max_timeout_resends);
        loop {
            assert!(budget.call_timeout(level, clock.now_ms).is_ok());
            sends += 1;
            // A fast failure answers immediately.
            match ladder.next_after(TransportFailure::RetryableStatus {
                retry_after_seconds: Some(MAX_RETRY_DELAY_SECONDS),
            }) {
                LadderStep::Resend { delay_seconds } => {
                    assert_eq!(delay_seconds, MAX_RETRY_DELAY_SECONDS);
                    let delay = budget
                        .backoff(delay_seconds, clock.now_ms)
                        .expect("the fast ladder never runs the budget out");
                    clock.spend(delay);
                }
                LadderStep::GiveUp { delay_seconds } => {
                    assert_eq!(delay_seconds, MAX_RETRY_DELAY_SECONDS);
                    if !is_last {
                        let delay = budget
                            .backoff(delay_seconds, clock.now_ms)
                            .expect("the boundary pause never runs the budget out");
                        clock.spend(delay);
                        boundary_delays += 1;
                    }
                    break;
                }
            }
        }
    }

    assert_eq!(sends, ANALYSIS_ATTEMPTS * TRANSPORT_TRIES);
    assert_eq!(boundary_delays, ANALYSIS_ATTEMPTS - 1);
    assert_eq!(
        clock.elapsed_seconds(),
        (ANALYSIS_ATTEMPTS * (TRANSPORT_TRIES - 1) + (ANALYSIS_ATTEMPTS - 1)) as u64
            * MAX_RETRY_DELAY_SECONDS
    );
    assert_eq!(clock.elapsed_seconds(), 420);
    assert!(clock.elapsed_seconds() <= ANALYSIS_RUN_BUDGET_SECONDS);
}

/// A mixed ladder (fast failures and timeouts interleaved) is bounded by the
/// budget on every step: a call never gets more than what is left, and a
/// sleep that would leave less than the floor is refused.
#[test]
fn mixed_ladder_never_exceeds_the_budget() {
    let config = LadderConfig::production();
    let budget = RunBudget::start(config, START_MS);
    let mut clock = Clock::new(config);
    let script = [
        TransportFailure::RetryableStatus {
            retry_after_seconds: None,
        },
        TransportFailure::Timeout,
        TransportFailure::FetchError,
        TransportFailure::Timeout,
        TransportFailure::RetryableStatus {
            retry_after_seconds: Some(MAX_RETRY_DELAY_SECONDS),
        },
    ];

    let mut ended_by_budget = false;
    'attempts: for attempt in 0..ANALYSIS_ATTEMPTS {
        let level = if attempt == 0 { "medium" } else { "high" };
        if budget.call_timeout(level, clock.now_ms).is_err() {
            ended_by_budget = true;
            break;
        }
        let mut ladder = TransportLadder::new(TRANSPORT_TRIES, config.max_timeout_resends);
        for failure in script {
            let Ok(timeout) = budget.call_timeout(level, clock.now_ms) else {
                ended_by_budget = true;
                break 'attempts;
            };
            assert!(timeout.as_secs() <= config.call_cap_seconds(level));
            assert!(timeout.as_secs() <= budget.remaining_seconds(clock.now_ms));
            if failure == TransportFailure::Timeout {
                clock.spend(timeout);
            }
            assert!(clock.elapsed_seconds() <= ANALYSIS_RUN_BUDGET_SECONDS);
            match ladder.next_after(failure) {
                LadderStep::Resend { delay_seconds } | LadderStep::GiveUp { delay_seconds } => {
                    match budget.backoff(delay_seconds, clock.now_ms) {
                        Ok(delay) => clock.spend(delay),
                        Err(BudgetExhausted) => {
                            ended_by_budget = true;
                            break 'attempts;
                        }
                    }
                }
            }
            assert!(clock.elapsed_seconds() <= ANALYSIS_RUN_BUDGET_SECONDS);
            if ladder.failed_tries() >= TRANSPORT_TRIES {
                break;
            }
        }
    }

    assert!(clock.elapsed_seconds() <= ANALYSIS_RUN_BUDGET_SECONDS);
    // Two full timeouts per attempt at both levels cannot fit three
    // attempts, so it is the budget that ends this run.
    assert!(ended_by_budget);
}

#[test]
fn call_timeout_is_the_level_cap_then_the_remainder_then_refused() {
    let config = LadderConfig::production();
    let budget = RunBudget::start(config, START_MS);
    let second = config.millis_per_second;

    assert_eq!(
        budget.call_timeout("medium", START_MS).unwrap().as_secs(),
        120
    );
    assert_eq!(
        budget.call_timeout("high", START_MS).unwrap().as_secs(),
        300
    );
    // Every level below high shares the medium cap.
    assert_eq!(budget.call_timeout("low", START_MS).unwrap().as_secs(), 120);

    let late = START_MS + 450 * second;
    assert_eq!(budget.remaining_seconds(late), 90);
    assert_eq!(budget.call_timeout("medium", late).unwrap().as_secs(), 90);
    assert_eq!(budget.call_timeout("high", late).unwrap().as_secs(), 90);

    let floor = START_MS + 510 * second;
    assert_eq!(budget.call_timeout("high", floor).unwrap().as_secs(), 30);
    let under = START_MS + 511 * second;
    assert_eq!(budget.call_timeout("high", under), Err(BudgetExhausted));
    assert_eq!(
        budget.call_timeout("medium", START_MS + 10_000 * second),
        Err(BudgetExhausted)
    );
}

#[test]
fn backoff_is_refused_when_it_would_not_leave_room_for_a_call() {
    let config = LadderConfig::production();
    let budget = RunBudget::start(config, START_MS);
    let second = config.millis_per_second;

    let plenty = START_MS + 100 * second;
    assert_eq!(budget.backoff(16, plenty).unwrap().as_secs(), 16);
    // 46 s left: a 16 s sleep leaves exactly the floor.
    let exact = START_MS + (540 - 46) * second;
    assert_eq!(budget.backoff(16, exact).unwrap().as_secs(), 16);
    // 45 s left: the sleep would leave less than the floor.
    let short = START_MS + (540 - 45) * second;
    assert_eq!(budget.backoff(16, short), Err(BudgetExhausted));
    assert_eq!(budget.backoff(0, short).unwrap().as_secs(), 0);
    assert_eq!(
        budget.backoff(0, START_MS + (540 - 29) * second),
        Err(BudgetExhausted)
    );
}

#[test]
fn timeouts_resend_once_immediately_then_give_up() {
    let mut ladder = TransportLadder::new(TRANSPORT_TRIES, MAX_TIMEOUT_RESENDS);
    assert_eq!(
        ladder.next_after(TransportFailure::Timeout),
        LadderStep::Resend { delay_seconds: 0 }
    );
    assert_eq!(
        ladder.next_after(TransportFailure::Timeout),
        LadderStep::GiveUp { delay_seconds: 0 }
    );
    assert_eq!(ladder.failed_tries(), 2);

    // A fast failure before the timeout does not buy a second resend.
    let mut mixed = TransportLadder::new(TRANSPORT_TRIES, MAX_TIMEOUT_RESENDS);
    assert_eq!(
        mixed.next_after(TransportFailure::FetchError),
        LadderStep::Resend { delay_seconds: 2 }
    );
    assert_eq!(
        mixed.next_after(TransportFailure::Timeout),
        LadderStep::Resend { delay_seconds: 0 }
    );
    assert_eq!(
        mixed.next_after(TransportFailure::Timeout),
        LadderStep::GiveUp { delay_seconds: 0 }
    );

    // Zero resends: the first timeout ends the ladder.
    let mut none = TransportLadder::new(TRANSPORT_TRIES, 0);
    assert_eq!(
        none.next_after(TransportFailure::Timeout),
        LadderStep::GiveUp { delay_seconds: 0 }
    );
}

/// A spent ladder hands its last failure's pause to the caller: the
/// `Retry-After` (capped) or the backoff step, never nothing.
#[test]
fn giving_up_carries_the_last_failures_pause_across_the_attempt_boundary() {
    let mut retry_after = TransportLadder::new(2, MAX_TIMEOUT_RESENDS);
    assert_eq!(
        retry_after.next_after(TransportFailure::RetryableStatus {
            retry_after_seconds: Some(9)
        }),
        LadderStep::Resend { delay_seconds: 9 }
    );
    assert_eq!(
        retry_after.next_after(TransportFailure::RetryableStatus {
            retry_after_seconds: Some(999)
        }),
        LadderStep::GiveUp {
            delay_seconds: MAX_RETRY_DELAY_SECONDS
        }
    );

    let mut backoff = TransportLadder::new(2, MAX_TIMEOUT_RESENDS);
    backoff.next_after(TransportFailure::FetchError);
    assert_eq!(
        backoff.next_after(TransportFailure::RetryableStatus {
            retry_after_seconds: None
        }),
        LadderStep::GiveUp {
            delay_seconds: backoff_seconds(2)
        }
    );

    let mut fetch = TransportLadder::new(1, MAX_TIMEOUT_RESENDS);
    assert_eq!(
        fetch.next_after(TransportFailure::FetchError),
        LadderStep::GiveUp {
            delay_seconds: backoff_seconds(1)
        }
    );
}

#[test]
fn fast_failures_get_five_tries_with_retry_after_honoured_and_capped() {
    let mut ladder = TransportLadder::new(TRANSPORT_TRIES, MAX_TIMEOUT_RESENDS);
    assert_eq!(
        ladder.next_after(TransportFailure::RetryableStatus {
            retry_after_seconds: Some(7)
        }),
        LadderStep::Resend { delay_seconds: 7 }
    );
    assert_eq!(
        ladder.next_after(TransportFailure::RetryableStatus {
            retry_after_seconds: None
        }),
        LadderStep::Resend { delay_seconds: 4 }
    );
    assert_eq!(
        ladder.next_after(TransportFailure::FetchError),
        LadderStep::Resend { delay_seconds: 8 }
    );
    assert_eq!(
        ladder.next_after(TransportFailure::RetryableStatus {
            retry_after_seconds: Some(999)
        }),
        LadderStep::Resend {
            delay_seconds: MAX_RETRY_DELAY_SECONDS
        }
    );
    assert_eq!(
        ladder.next_after(TransportFailure::RetryableStatus {
            retry_after_seconds: None
        }),
        LadderStep::GiveUp {
            delay_seconds: backoff_seconds(TRANSPORT_TRIES)
        }
    );
    assert_eq!(ladder.failed_tries(), TRANSPORT_TRIES);
}

#[test]
fn time_scale_override_applies_only_in_development_within_bounds() {
    let production = LadderConfig::production();
    assert_eq!(production.millis_per_second, 1_000);
    assert_eq!(
        LadderConfig::resolve(Some("development"), Some("10")).millis_per_second,
        10
    );
    assert_eq!(
        LadderConfig::resolve(Some(" development "), Some(" 1 ")).millis_per_second,
        1
    );
    assert_eq!(
        LadderConfig::resolve(Some("development"), Some("1000")).millis_per_second,
        1_000
    );
    for (lane, value) in [
        (Some("production"), Some("10")),
        (Some("prod-staging"), Some("10")),
        (None, Some("10")),
        (Some("development"), Some("0")),
        (Some("development"), Some("1001")),
        (Some("development"), Some("fast")),
        (Some("development"), Some("")),
        (Some("development"), None),
    ] {
        let resolved = LadderConfig::resolve(lane, value);
        assert_eq!(resolved, production, "{lane:?} {value:?}");
    }
    // The override never touches the ladder shape.
    let scaled = LadderConfig::resolve(Some("development"), Some("10"));
    assert_eq!(
        LadderConfig {
            millis_per_second: 1_000,
            ..scaled
        },
        production
    );
}

#[test]
fn scaled_ladder_keeps_every_ratio() {
    let config = LadderConfig::resolve(Some("development"), Some("10"));
    assert_eq!(config.duration(120).as_millis(), 1_200);
    assert_eq!(config.duration(300).as_millis(), 3_000);
    let budget = RunBudget::start(config, START_MS);
    assert_eq!(budget.remaining_seconds(START_MS), 540);
    assert_eq!(
        budget.call_timeout("medium", START_MS).unwrap().as_millis(),
        1_200
    );
    assert_eq!(
        budget
            .call_timeout("high", START_MS + 2_400)
            .unwrap()
            .as_millis(),
        3_000
    );
    assert_eq!(budget.backoff(16, START_MS).unwrap().as_millis(), 160);
    // After 2 x medium + high the budget is spent, exactly as in real time.
    assert_eq!(
        budget.call_timeout("high", START_MS + 5_400),
        Err(BudgetExhausted)
    );
    assert_eq!(budget.remaining_seconds(START_MS + 5_400 - 10), 1);
}

/// Async runs anchor to the persisted job start (whole seconds), so time
/// spent before the run task first looks at the clock is already spent.
#[test]
fn budget_anchors_to_the_persisted_start_and_saturates() {
    let config = LadderConfig::production();
    let started_at_seconds: i64 = 1_760_000_000;
    let anchor_ms = u64::try_from(started_at_seconds).unwrap() * 1_000;
    let budget = RunBudget::start(config, anchor_ms);

    let first_look = anchor_ms + 100 * 1_000;
    assert_eq!(budget.remaining_seconds(first_look), 440);
    assert_eq!(
        budget.call_timeout("high", first_look).unwrap().as_secs(),
        300
    );
    // A clock reading before the anchor cannot grant more than the budget.
    assert_eq!(budget.remaining_seconds(anchor_ms - 60_000), 540);
    assert_eq!(budget.remaining_seconds(0), 540);
    // A clock far past the deadline saturates to zero rather than wrapping.
    assert_eq!(budget.remaining_seconds(u64::MAX), 0);
    assert_eq!(budget.call_timeout("high", u64::MAX), Err(BudgetExhausted));
    let late = RunBudget::start(config, u64::MAX - 1_000);
    assert_eq!(late.remaining_seconds(u64::MAX), 0);
}

#[test]
fn attempt_failures_map_to_the_existing_typed_codes() {
    let validation = AttemptFailure::Validation("id_discipline,chapter_order".to_string());
    assert_eq!(
        validation.into_error(),
        UpstreamError::with_detail(502, "invalid_model_output", "id_discipline,chapter_order")
    );
    assert_eq!(
        AttemptFailure::Parse(GeminiParseError::MaxTokensTruncated).into_error(),
        UpstreamError::new(502, "model_output_truncated")
    );
    assert_eq!(
        AttemptFailure::Parse(GeminiParseError::MalformedModelJson).into_error(),
        UpstreamError::new(502, "invalid_model_output")
    );
    assert_eq!(
        AttemptFailure::Parse(GeminiParseError::NonStopFinishReason).into_error(),
        UpstreamError::new(502, "invalid_model_output")
    );
    let transport = UpstreamError::new(503, "gemini_retry_exhausted");
    assert_eq!(
        AttemptFailure::Transport(transport.clone()).into_error(),
        transport
    );
    // Budget exhausted before any attempt failed: the deterministic code.
    assert_eq!(
        run_failure_error(None),
        UpstreamError::new(503, "gemini_timeout")
    );
    assert_eq!(
        run_failure_error(Some(AttemptFailure::Transport(UpstreamError::new(
            502,
            "worker_fetch_error"
        )))),
        UpstreamError::new(502, "worker_fetch_error")
    );
}
