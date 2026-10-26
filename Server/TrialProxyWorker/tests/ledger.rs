//! The accounting state machine on fake clocks, against both stores.

mod support;

use opencast_trial_proxy_worker::bundle::Feature;
use opencast_trial_proxy_worker::config::{
    cost_micros, price_table, LedgerConfig, Mode, MAX_STORED_INTEGER,
};
use opencast_trial_proxy_worker::ledger::{
    self, AlertKind, Decision, Lane, LedgerStore, MemoryStore, PauseReason, RefusalCode,
    ReservationState, SettleResult, StoreError, EXPIRY_MARGIN_MS,
};
use opencast_trial_proxy_worker::provider::{AmbiguousClass, SettleOutcome, Usage};
use support::{at, config, flip, Harness, Mem, Req, Rng, Sql, MODEL};

const HOUR: i64 = 3_600_000;
/// gemini-3.8-flash's documented maximum input (the seed price rows').
const MAX_INPUT: u64 = 1_048_576;

/// One window's reservation in trial mode: the maximum input and the
/// default output cap at the 2027 price.
fn trial_window() -> u64 {
    cost_micros(MAX_INPUT, 1_500_000) + cost_micros(16_384, 7_500_000)
}

/// The same at the 2026 promotional price.
fn open_window() -> u64 {
    cost_micros(MAX_INPUT, 750_000) + cost_micros(16_384, 3_750_000)
}

/// Usage beyond the documented limits: the premise the reservation rests on
/// failing (the overrun path).
fn beyond_limits() -> SettleOutcome {
    usage(MAX_INPUT + 500_000, 1_000)
}
const DAY: i64 = 24 * HOUR;

fn trial_day() -> i64 {
    at("2027-01-15T12:00:00Z")
}

fn open_day() -> i64 {
    at("2026-12-15T12:00:00Z")
}

fn admit<H: Harness>(h: &mut H, config: &LedgerConfig, now: i64, req: &Req) -> Decision {
    h.op(|store| ledger::admit(store, config, now, &req.build()))
        .expect("admit")
        .decision
}

fn settle<H: Harness>(h: &mut H, now: i64, id: &str, outcome: SettleOutcome) -> SettleResult {
    h.op(|store| ledger::settle(store, now, id, &outcome))
        .expect("settle")
        .result
}

fn usage(prompt: u64, output: u64) -> SettleOutcome {
    SettleOutcome::Usage {
        status: 200,
        usage: Usage {
            prompt_tokens: prompt,
            output_tokens: output,
        },
    }
}

fn admitted(decision: &Decision) -> u64 {
    match decision {
        Decision::Admitted {
            reserved_micros, ..
        } => *reserved_micros,
        other => panic!("expected admission, got {other:?}"),
    }
}

fn refused(decision: &Decision) -> RefusalCode {
    match decision {
        Decision::Refused { code, .. } => *code,
        other => panic!("expected refusal, got {other:?}"),
    }
}

fn check_month_sums<H: Harness>(h: &H) {
    for (month, recorded, sum) in h.month_sums() {
        assert_eq!(recorded, sum, "I1 broken for {month}");
    }
}

/// Runs one (one-window) analysis to completion.
fn run_once<H: Harness>(
    h: &mut H,
    config: &LedgerConfig,
    now: i64,
    subject: &str,
    run: &str,
) -> Decision {
    let id = format!("{subject}-{run}");
    let decision = admit(h, config, now, &Req::new(&id, subject, run, 0));
    if matches!(decision, Decision::Admitted { .. }) {
        settle(h, now + 1_000, &id, usage(9_000, 2_000));
    }
    decision
}

macro_rules! both {
    ($($name:ident),* $(,)?) => {
        mod memory {
            $(#[test] fn $name() { super::$name(&mut super::Mem(super::MemoryStore::default())); })*
        }
        mod sqlite {
            $(#[test] fn $name() { super::$name(&mut super::Sql::new()); })*
        }
    };
}

both!(
    five_units_per_install_after_the_flip,
    resumed_runs_consume_nothing,
    open_mode_runs_never_consume_and_count_would_refuse,
    a_run_seeded_while_open_consumes_its_unit_after_the_flip,
    bearer_lane_has_no_units_and_its_own_caps,
    run_bound_windows_and_tokens,
    one_window_in_flight_per_install,
    bearer_busy_is_per_run,
    lock_expiry_keeps_the_charge_and_frees_the_install,
    a_settle_after_the_deadline_releases_nothing,
    ceiling_mid_run_in_flight_window_completes,
    month_rollover_at_utc_midnight_releases_nothing,
    price_switch_and_month_spill_at_the_flip,
    a_window_reaching_into_a_full_month_is_refused_and_names_it,
    mode_flip_at_trial_mode_starts_at,
    open_mode_backstop_alerts_once_a_day,
    every_settlement_branch_charges_as_pinned,
    settle_is_idempotent,
    usage_above_the_reservation_counts_at_the_gate,
    replay_returns_the_admission_only_for_the_same_open_request,
    a_client_always_asking_high_pays_no_more,
    no_price_pauses_and_alerts,
    month_paused_follows_remaining_room,
    concurrent_admissions_cannot_cross_the_ceiling,
    reported_overruns_still_keep_the_charge_under_the_ceiling,
    the_window_constant_covers_any_documented_usage,
    an_overrun_alerts_the_day_it_happens,
    a_reservation_stored_below_the_constant_never_replays,
    month_paused_agrees_with_the_gate_across_a_price_switch,
    month_paused_agrees_with_the_gate_for_a_full_spill_month,
    a_replay_under_an_edited_price_row_is_refused,
    an_overflowing_overrun_saturates_and_pauses_instead_of_rolling_back,
    prune_keeps_runs_that_consumed_a_unit,
    provider_failure_alert_bursty_not_sparse,
    mirror_failures_alert_on_the_fifth,
    day_summaries_are_taken_once,
);

fn five_units_per_install_after_the_flip<H: Harness>(h: &mut H) {
    let config = config();
    let now = trial_day();
    for run in 0..5 {
        admitted(&run_once(
            h,
            &config,
            now + run * 10_000,
            "install-a",
            &format!("run-{run}"),
        ));
    }
    assert_eq!(
        refused(&run_once(h, &config, now + 60_000, "install-a", "run-5")),
        RefusalCode::TrialExhausted
    );
    // Another install has its own five.
    admitted(&run_once(h, &config, now + 70_000, "install-b", "run-0"));
    let status = h
        .op(|s| {
            ledger::status(
                s,
                &config,
                now + 80_000,
                "install-a",
                Lane::AppAttest,
                MODEL,
                16_384,
                117_000,
            )
        })
        .unwrap();
    assert_eq!((status.mode, status.units_remaining), (Mode::Trial, 0));
    check_month_sums(h);
}

fn resumed_runs_consume_nothing<H: Harness>(h: &mut H) {
    let config = config();
    let now = trial_day();
    for run in 0..5 {
        admitted(&run_once(
            h,
            &config,
            now + run * 10_000,
            "install-a",
            &format!("run-{run}"),
        ));
    }
    // The fifth run's next window and a retry of its first window still go.
    let next = admit(
        h,
        &config,
        now + 60_000,
        &Req::new("w1", "install-a", "run-4", 1),
    );
    admitted(&next);
    settle(h, now + 61_000, "w1", usage(9_000, 1_000));
    admitted(&admit(
        h,
        &config,
        now + 62_000,
        &Req::new("w0-retry", "install-a", "run-4", 0),
    ));
    let installed = h.store().install("install-a").unwrap().unwrap();
    assert_eq!(installed.trial_units_used, 5);
}

fn open_mode_runs_never_consume_and_count_would_refuse<H: Harness>(h: &mut H) {
    let config = config();
    let now = open_day();
    for run in 0..7 {
        admitted(&run_once(
            h,
            &config,
            now + run * 10_000,
            "install-a",
            &format!("run-{run}"),
        ));
    }
    let install = h.store().install("install-a").unwrap().unwrap();
    assert_eq!((install.trial_units_used, install.open_runs), (0, 7));
    let day = h.store().day(now.div_euclid(DAY)).unwrap().unwrap();
    assert_eq!(
        day.would_refuse_runs, 2,
        "runs six and seven would be refused after the flip"
    );
    let status = h
        .op(|s| {
            ledger::status(
                s,
                &config,
                now,
                "install-a",
                Lane::AppAttest,
                MODEL,
                16_384,
                117_000,
            )
        })
        .unwrap();
    assert_eq!(
        (status.mode, status.units_remaining, status.month_paused),
        (Mode::Open, 5, false)
    );
    assert_eq!(ledger::open_mode_status(&config), status);
}

fn a_run_seeded_while_open_consumes_its_unit_after_the_flip<H: Harness>(h: &mut H) {
    let config = config();
    for run in 0..8 {
        admitted(&run_once(
            h,
            &config,
            open_day() + run * 10_000,
            "install-a",
            &format!("seed-{run}"),
        ));
    }
    // Continuing those runs in January costs a unit each, up to five.
    let now = trial_day();
    for run in 0..5 {
        let id = format!("jan-{run}");
        admitted(&admit(
            h,
            &config,
            now + run * 10_000,
            &Req::new(&id, "install-a", &format!("seed-{run}"), 1),
        ));
        settle(h, now + run * 10_000 + 1_000, &id, usage(100, 100));
    }
    assert_eq!(
        refused(&admit(
            h,
            &config,
            now + 90_000,
            &Req::new("jan-5", "install-a", "seed-5", 1)
        )),
        RefusalCode::TrialExhausted
    );
    // A unit-consuming run resumes freely afterwards.
    admitted(&admit(
        h,
        &config,
        now + 95_000,
        &Req::new("jan-0b", "install-a", "seed-0", 2),
    ));
}

fn bearer_lane_has_no_units_and_its_own_caps<H: Harness>(h: &mut H) {
    let config = config();
    let now = trial_day();
    for run in 0..40 {
        let id = format!("b{run}");
        admitted(&admit(
            h,
            &config,
            now + run * 1_000,
            &Req::new(&id, "bearer:ops", &format!("r{run}"), 0).bearer(),
        ));
        settle(h, now + run * 1_000 + 500, &id, usage(10, 10));
    }
    assert_eq!(
        refused(&admit(
            h,
            &config,
            now + 50_000,
            &Req::new("b40", "bearer:ops", "r40", 0).bearer()
        )),
        RefusalCode::BearerLimited
    );
    assert!(h.store().install("bearer:ops").unwrap().is_none());
    // The token cap, on the next UTC day: five runs of 399,000 (each under
    // the run bound), then 5,001 more crosses 2,000,000.
    let tomorrow = now + DAY;
    for run in 0..5 {
        let id = format!("t{run}");
        admitted(&admit(
            h,
            &config,
            tomorrow + run,
            &Req::new(&id, "bearer:ops", &id, 0).bearer().input(399_000),
        ));
        settle(h, tomorrow + run, &id, usage(10, 10));
    }
    assert_eq!(
        refused(&admit(
            h,
            &config,
            tomorrow + 10,
            &Req::new("t5", "bearer:ops", "t5", 0).bearer().input(5_001)
        )),
        RefusalCode::BearerLimited
    );
    admitted(&admit(
        h,
        &config,
        tomorrow + 11,
        &Req::new("t6", "bearer:ops", "t6", 0).bearer().input(5_000),
    ));
    let status = h
        .op(|s| {
            ledger::status(
                s,
                &config,
                now,
                "bearer:ops",
                Lane::Bearer,
                MODEL,
                16_384,
                117_000,
            )
        })
        .unwrap();
    assert_eq!(status.units_remaining, 5);
}

fn run_bound_windows_and_tokens<H: Harness>(h: &mut H) {
    let config = config();
    let now = trial_day();
    for window in 0..12u16 {
        let id = format!("w{window}");
        admitted(&admit(
            h,
            &config,
            now + i64::from(window) * 1_000,
            &Req::new(&id, "install-a", "run", window),
        ));
        settle(h, now + i64::from(window) * 1_000 + 500, &id, usage(10, 10));
    }
    assert_eq!(
        refused(&admit(
            h,
            &config,
            now + 20_000,
            &Req::new("w12", "install-a", "run", 12)
        )),
        RefusalCode::TrialRunBound
    );
    // A retry of a window the run already has is not a new window.
    admitted(&admit(
        h,
        &config,
        now + 21_000,
        &Req::new("w3-retry", "install-a", "run", 3),
    ));
    settle(h, now + 21_500, "w3-retry", usage(10, 10));
    // Tokens: 12 × 10,000 reserved so far; a window taking it past 400,000 is refused.
    assert_eq!(
        refused(&admit(
            h,
            &config,
            now + 22_000,
            &Req::new("big", "install-a", "run", 4).input(280_001)
        )),
        RefusalCode::TrialRunBound
    );
    admitted(&admit(
        h,
        &config,
        now + 23_000,
        &Req::new("fits", "install-a", "run", 4).input(270_000),
    ));
    let run = h.store().run("install-a", "run").unwrap().unwrap();
    assert_eq!(
        (run.windows.len(), run.reserved_input_tokens),
        (12, 400_000)
    );
    // The run bound counts Google's count; the money reservation is the
    // window constant on the model's maximum input.
    admitted(&admit(
        h,
        &config,
        now + 300_000,
        &Req::new("counted", "install-c", "run", 0).input(390_000),
    ));
    let run = h.store().run("install-c", "run").unwrap().unwrap();
    assert_eq!(run.reserved_input_tokens, 390_000);
    let reservation = h.store().reservation("counted").unwrap().unwrap();
    assert_eq!(
        (reservation.input_tokens, reservation.input_bound_tokens),
        (390_000, MAX_INPUT)
    );
    assert_eq!(reservation.reserved_micros, trial_window());
    // A new run whose first window is over the bound is refused outright.
    assert_eq!(
        refused(&admit(
            h,
            &config,
            now + 400_000,
            &Req::new("huge", "install-b", "run", 0).input(400_001)
        )),
        RefusalCode::TrialRunBound
    );
}

fn one_window_in_flight_per_install<H: Harness>(h: &mut H) {
    let config = config();
    let now = trial_day();
    admitted(&admit(
        h,
        &config,
        now,
        &Req::new("a", "install-a", "run-1", 0),
    ));
    let busy = admit(
        h,
        &config,
        now + 1_000,
        &Req::new("b", "install-a", "run-2", 0),
    );
    match busy {
        Decision::Refused {
            code: RefusalCode::TrialBusy,
            retry_after_seconds: Some(seconds),
            ..
        } => assert!((1..=10).contains(&seconds), "{seconds}"),
        other => panic!("{other:?}"),
    }
    // Same run, next window: also busy.
    assert_eq!(
        refused(&admit(
            h,
            &config,
            now + 2_000,
            &Req::new("c", "install-a", "run-1", 1)
        )),
        RefusalCode::TrialBusy
    );
    // Another install is not blocked.
    admitted(&admit(
        h,
        &config,
        now + 2_000,
        &Req::new("d", "install-b", "run-1", 0),
    ));
    settle(h, now + 3_000, "a", usage(10, 10));
    admitted(&admit(
        h,
        &config,
        now + 4_000,
        &Req::new("b2", "install-a", "run-2", 0),
    ));
    // A busy refusal consumed nothing.
    assert_eq!(
        h.store()
            .install("install-a")
            .unwrap()
            .unwrap()
            .trial_units_used,
        2
    );
}

fn bearer_busy_is_per_run<H: Harness>(h: &mut H) {
    let config = config();
    let now = trial_day();
    admitted(&admit(
        h,
        &config,
        now,
        &Req::new("a", "bearer:ops", "run-1", 0).bearer(),
    ));
    admitted(&admit(
        h,
        &config,
        now,
        &Req::new("b", "bearer:ops", "run-2", 0).bearer(),
    ));
    assert_eq!(
        refused(&admit(
            h,
            &config,
            now,
            &Req::new("c", "bearer:ops", "run-1", 1).bearer()
        )),
        RefusalCode::TrialBusy
    );
}

fn lock_expiry_keeps_the_charge_and_frees_the_install<H: Harness>(h: &mut H) {
    let config = config();
    let now = trial_day();
    let reserved = admitted(&admit(
        h,
        &config,
        now,
        &Req::new("lost", "install-a", "run", 0).budget_ms(20_000),
    ));
    let deadline = now + 20_000 + EXPIRY_MARGIN_MS;
    assert_eq!(
        refused(&admit(
            h,
            &config,
            deadline - 1,
            &Req::new("retry1", "install-a", "run", 0)
        )),
        RefusalCode::TrialBusy
    );
    // At the deadline the lost reservation expires lazily: charged in full,
    // and the device's retry is a new reservation.
    let retry = admit(
        h,
        &config,
        deadline,
        &Req::new("retry2", "install-a", "run", 0),
    );
    admitted(&retry);
    let lost = h.store().reservation("lost").unwrap().unwrap();
    assert_eq!(
        (lost.state, lost.charged_micros),
        (ReservationState::Expired, reserved)
    );
    assert_eq!(
        h.store()
            .day(deadline.div_euclid(DAY))
            .unwrap()
            .unwrap()
            .expired,
        1
    );
    // The alarm path expires too.
    admitted(&admit(
        h,
        &config,
        now,
        &Req::new("other", "install-b", "run", 0),
    ));
    let expired = h.op(|s| ledger::expire_due(s, now + DAY, 100)).unwrap();
    assert_eq!(expired, 2);
    check_month_sums(h);
}

fn a_settle_after_the_deadline_releases_nothing<H: Harness>(h: &mut H) {
    let config = config();
    let now = trial_day();
    let reserved = admitted(&admit(
        h,
        &config,
        now,
        &Req::new("late", "install-a", "run", 0).budget_ms(10_000),
    ));
    let result = settle(h, now + 10_000 + EXPIRY_MARGIN_MS, "late", usage(1, 1));
    assert_eq!(
        result,
        SettleResult::AlreadyFinal {
            state: ReservationState::Expired,
            reserved_micros: reserved,
            charged_micros: reserved
        }
    );
    let month = h.store().month("2027-01").unwrap().unwrap();
    assert_eq!(month.charged_micros, reserved);
}

fn ceiling_mid_run_in_flight_window_completes<H: Harness>(h: &mut H) {
    let mut config = config();
    // One window's constant at list price: three fit, a fourth does not.
    config.ceiling_micros = 3 * trial_window() + trial_window() / 2;
    let now = trial_day();
    let one = admitted(&admit(h, &config, now, &Req::new("a0", "a", "run", 0)));
    assert_eq!(one, trial_window());
    admitted(&admit(h, &config, now, &Req::new("b0", "b", "run", 0)));
    admitted(&admit(h, &config, now, &Req::new("c0", "c", "run", 0)));
    // The fourth window does not fit: paused, with one alert for the month.
    let paused = h
        .op(|s| ledger::admit(s, &config, now, &Req::new("d0", "d", "run", 0).build()))
        .unwrap();
    assert!(matches!(
        paused.decision,
        Decision::Refused {
            code: RefusalCode::TrialPaused,
            pause: Some(PauseReason::Ceiling),
            ..
        }
    ));
    assert_eq!(paused.alerts.len(), 1);
    assert_eq!(paused.alerts[0].kind, AlertKind::Ceiling);
    // A's window in flight completes and releases most of its reservation.
    settle(h, now + 5_000, "a0", usage(10_000, 1_000));
    // A's run continues (no new unit) once there is room; d's new run fits too.
    admitted(&admit(
        h,
        &config,
        now + 6_000,
        &Req::new("a1", "a", "run", 1),
    ));
    let again = h
        .op(|s| {
            ledger::admit(
                s,
                &config,
                now + 7_000,
                &Req::new("d1", "d", "run", 0).build(),
            )
        })
        .unwrap();
    assert!(again.alerts.is_empty(), "the ceiling alerts once a month");
    check_month_sums(h);
    let month = h.store().month("2027-01").unwrap().unwrap();
    assert!(month.charged_micros <= config.ceiling_micros);
    // The refused run never consumed its unit.
    assert_eq!(
        h.store()
            .install("d")
            .unwrap()
            .map(|i| i.trial_units_used)
            .unwrap_or(0),
        u32::from(matches!(again.decision, Decision::Admitted { .. }))
    );
}

fn month_rollover_at_utc_midnight_releases_nothing<H: Harness>(h: &mut H) {
    let mut config = config();
    config.ceiling_micros = 2 * trial_window() + trial_window() / 2;
    let late_january = at("2027-01-31T23:50:00Z");
    admitted(&admit(
        h,
        &config,
        late_january,
        &Req::new("a", "a", "run", 0).budget_ms(10_000),
    ));
    admitted(&admit(
        h,
        &config,
        late_january,
        &Req::new("b", "b", "run", 0).budget_ms(10_000),
    ));
    assert_eq!(
        refused(&admit(
            h,
            &config,
            late_january,
            &Req::new("c", "c", "run", 0).budget_ms(10_000)
        )),
        RefusalCode::TrialPaused
    );
    settle(h, late_january + 5_000, "a", usage(100, 100));
    let january_settled = cost_micros(100, 1_500_000) + cost_micros(100, 7_500_000);
    // b is never settled: it expires in January and stays charged there.
    let february = at("2027-02-01T00:00:00Z");
    admitted(&admit(
        h,
        &config,
        february,
        &Req::new("c2", "c", "run", 0).budget_ms(10_000),
    ));
    assert_eq!(h.op(|s| ledger::expire_due(s, february, 10)).unwrap(), 1);
    let january = h.store().month("2027-01").unwrap().unwrap();
    let feb = h.store().month("2027-02").unwrap().unwrap();
    assert_eq!(january.charged_micros, january_settled + trial_window());
    assert_eq!(
        feb.charged_micros,
        trial_window(),
        "the new month starts from nothing"
    );
    check_month_sums(h);
}

fn price_switch_and_month_spill_at_the_flip<H: Harness>(h: &mut H) {
    let config = config();
    // Wholly before the switch: the promotional price.
    let early = at("2026-12-31T23:00:00Z");
    assert_eq!(
        admitted(&admit(h, &config, early, &Req::new("early", "a", "r1", 0))),
        open_window()
    );
    settle(h, early + 1_000, "early", usage(10_000, 16_384));
    // A window whose lock reaches past midnight reserves at the new price and
    // is charged to January as well.
    let straddle = at("2026-12-31T23:58:00Z");
    let reserved = admitted(&admit(
        h,
        &config,
        straddle,
        &Req::new("straddle", "b", "r1", 0),
    ));
    assert_eq!(reserved, trial_window());
    let reservation = h.store().reservation("straddle").unwrap().unwrap();
    assert_eq!(
        (
            reservation.month.as_str(),
            reservation.spill_month.as_deref(),
            reservation.mode
        ),
        ("2026-12", Some("2027-01"), Mode::Open)
    );
    assert_eq!(
        h.store().month("2027-01").unwrap().unwrap().charged_micros,
        trial_window()
    );
    // Settlement releases from both months at the reservation's own prices.
    settle(h, flip() + 30_000, "straddle", usage(10_000, 1_000));
    let charged = cost_micros(10_000, 1_500_000) + cost_micros(1_000, 7_500_000);
    assert_eq!(
        h.store().month("2027-01").unwrap().unwrap().charged_micros,
        charged
    );
    assert_eq!(
        h.store().month("2026-12").unwrap().unwrap().charged_micros,
        7_500 + 61_440 + charged
    );
    check_month_sums(h);
}

fn a_window_reaching_into_a_full_month_is_refused_and_names_it<H: Harness>(h: &mut H) {
    let mut config = config();
    config.ceiling_micros = 3 * trial_window() + trial_window() / 2;
    // January is nearly full: three list-price windows, half of one left.
    for n in 0..3 {
        let id = format!("j{n}");
        admitted(&admit(
            h,
            &config,
            trial_day(),
            &Req::new(&id, &id, "run", 0),
        ));
    }
    // A late-December window whose lock reaches past midnight must also fit
    // January: it does not.
    let late = at("2026-12-31T23:58:00Z");
    let result = h
        .op(|s| ledger::admit(s, &config, late, &Req::new("late", "d", "run", 0).build()))
        .unwrap();
    assert!(matches!(
        result.decision,
        Decision::Refused {
            code: RefusalCode::TrialPaused,
            pause: Some(PauseReason::Ceiling),
            mode: Mode::Open,
            ..
        }
    ));
    assert_eq!(result.alerts.len(), 1);
    assert_eq!(
        result.alerts[0].period, "2027-01",
        "the alert names the month that did not fit"
    );
    assert_eq!(result.alerts[0].value_a, 3 * trial_window());
    assert!(h
        .store()
        .month("2027-01")
        .unwrap()
        .unwrap()
        .paused_at
        .is_some());
    // An earlier window that ends before midnight is December's alone.
    admitted(&admit(
        h,
        &config,
        at("2026-12-31T23:00:00Z"),
        &Req::new("early", "e", "run", 0),
    ));
    for (_, charged, _) in h.month_sums() {
        assert!(charged <= config.ceiling_micros);
    }
    check_month_sums(h);
}

fn mode_flip_at_trial_mode_starts_at<H: Harness>(h: &mut H) {
    let config = config();
    assert_eq!(config.mode_at(flip() - 1), Mode::Open);
    assert_eq!(config.mode_at(flip()), Mode::Trial);
    let before = admit(
        h,
        &config,
        flip() - 1,
        &Req::new("o", "a", "open-run", 0).budget_ms(1_000),
    );
    assert!(matches!(
        before,
        Decision::Admitted {
            mode: Mode::Open,
            ..
        }
    ));
    settle(h, flip() - 1, "o", usage(1, 1));
    assert_eq!(h.store().install("a").unwrap().unwrap().trial_units_used, 0);
    let after = admit(h, &config, flip(), &Req::new("t", "a", "trial-run", 0));
    assert!(matches!(
        after,
        Decision::Admitted {
            mode: Mode::Trial,
            ..
        }
    ));
    assert_eq!(h.store().install("a").unwrap().unwrap().trial_units_used, 1);
}

fn open_mode_backstop_alerts_once_a_day<H: Harness>(h: &mut H) {
    let mut config = config();
    config.open_daily_requests = 3;
    let now = open_day();
    for n in 0..3 {
        run_once(h, &config, now + n * 1_000, &format!("i{n}"), "run");
    }
    let first = h
        .op(|s| {
            ledger::admit(
                s,
                &config,
                now + 10_000,
                &Req::new("x", "i9", "run", 0).build(),
            )
        })
        .unwrap();
    assert!(matches!(
        first.decision,
        Decision::Refused {
            code: RefusalCode::TrialPaused,
            pause: Some(PauseReason::Backstop),
            mode: Mode::Open,
            ..
        }
    ));
    assert_eq!(first.alerts.len(), 1);
    let second = h
        .op(|s| {
            ledger::admit(
                s,
                &config,
                now + 11_000,
                &Req::new("y", "i9", "run", 0).build(),
            )
        })
        .unwrap();
    assert!(second.alerts.is_empty());
    // The token backstop, and the next UTC day starts fresh.
    config.open_daily_requests = 300;
    config.open_daily_input_tokens = 50_000;
    assert_eq!(
        refused(&admit(
            h,
            &config,
            now + 12_000,
            &Req::new("z", "i9", "run", 0).input(25_000)
        )),
        RefusalCode::TrialPaused
    );
    admitted(&admit(
        h,
        &config,
        now + DAY,
        &Req::new("z2", "i9", "run", 0).input(25_000),
    ));
}

fn every_settlement_branch_charges_as_pinned<H: Harness>(h: &mut H) {
    let config = config();
    let now = trial_day();
    type Expected = Box<dyn Fn(u64) -> u64>;
    let cases: Vec<(SettleOutcome, Expected)> = vec![
        (
            usage(2_000, 3_000),
            Box::new(|_| cost_micros(2_000, 1_500_000) + cost_micros(3_000, 7_500_000)),
        ),
        (SettleOutcome::Rejected { status: 400 }, Box::new(|_| 0)),
        (SettleOutcome::Rejected { status: 401 }, Box::new(|_| 0)),
        (SettleOutcome::Rejected { status: 403 }, Box::new(|_| 0)),
        (SettleOutcome::Rejected { status: 404 }, Box::new(|_| 0)),
        (SettleOutcome::Rejected { status: 429 }, Box::new(|_| 0)),
        (SettleOutcome::NotDispatched, Box::new(|_| 0)),
        (
            SettleOutcome::Ambiguous {
                class: AmbiguousClass::Status5xx,
                status: Some(503),
            },
            Box::new(|r| r),
        ),
        (
            SettleOutcome::Ambiguous {
                class: AmbiguousClass::Timeout,
                status: None,
            },
            Box::new(|r| r),
        ),
        (
            SettleOutcome::Ambiguous {
                class: AmbiguousClass::Unreachable,
                status: None,
            },
            Box::new(|r| r),
        ),
        (
            SettleOutcome::Ambiguous {
                class: AmbiguousClass::NoUsage,
                status: Some(200),
            },
            Box::new(|r| r),
        ),
        (
            SettleOutcome::Ambiguous {
                class: AmbiguousClass::BodyTooLarge,
                status: Some(200),
            },
            Box::new(|r| r),
        ),
        (
            SettleOutcome::Ambiguous {
                class: AmbiguousClass::Status4xx,
                status: Some(408),
            },
            Box::new(|r| r),
        ),
        (
            SettleOutcome::Ambiguous {
                class: AmbiguousClass::Status3xx,
                status: Some(302),
            },
            Box::new(|r| r),
        ),
    ];
    for (index, (outcome, expected)) in cases.into_iter().enumerate() {
        let id = format!("s{index}");
        let subject = format!("install-{index}");
        let reserved = admitted(&admit(h, &config, now, &Req::new(&id, &subject, "run", 0)));
        match settle(h, now + 1_000, &id, outcome) {
            SettleResult::Settled {
                charged_micros,
                reserved_micros,
                overrun_micros,
            } => {
                assert_eq!(reserved_micros, reserved);
                assert_eq!(charged_micros, expected(reserved), "{outcome:?}");
                assert!(charged_micros <= reserved_micros);
                assert_eq!(overrun_micros, 0);
            }
            other => panic!("{other:?}"),
        }
    }
    check_month_sums(h);
}

fn settle_is_idempotent<H: Harness>(h: &mut H) {
    let config = config();
    let now = trial_day();
    admitted(&admit(h, &config, now, &Req::new("x", "a", "run", 0)));
    let first = settle(h, now + 1, "x", usage(100, 100));
    let month_after_first = h.store().month("2027-01").unwrap().unwrap().charged_micros;
    for outcome in [
        usage(1, 1),
        SettleOutcome::NotDispatched,
        SettleOutcome::Ambiguous {
            class: AmbiguousClass::Timeout,
            status: None,
        },
    ] {
        let again = settle(h, now + 2, "x", outcome);
        assert!(
            matches!(
                again,
                SettleResult::AlreadyFinal {
                    state: ReservationState::Settled,
                    ..
                }
            ),
            "{again:?}"
        );
    }
    assert!(matches!(first, SettleResult::Settled { .. }));
    assert_eq!(
        h.store().month("2027-01").unwrap().unwrap().charged_micros,
        month_after_first
    );
    assert_eq!(
        settle(h, now, "never-admitted", usage(1, 1)),
        SettleResult::Unknown
    );
}

fn usage_above_the_reservation_counts_at_the_gate<H: Harness>(h: &mut H) {
    let mut config = config();
    config.ceiling_micros = 4 * trial_window();
    let now = trial_day();
    let reserved = admitted(&admit(h, &config, now, &Req::new("x", "a", "run", 0)));
    // The reply reports more input than the model's documented maximum.
    let result = settle(h, now + 1, "x", beyond_limits());
    let actual = cost_micros(MAX_INPUT + 500_000, 1_500_000) + cost_micros(1_000, 7_500_000);
    match result {
        SettleResult::Settled {
            charged_micros,
            overrun_micros,
            ..
        } => {
            assert_eq!(
                charged_micros, reserved,
                "a charge never exceeds its reservation"
            );
            assert_eq!(overrun_micros, actual - reserved);
        }
        other => panic!("{other:?}"),
    }
    let month = h.store().month("2027-01").unwrap().unwrap();
    assert_eq!(month.overrun_micros, actual - reserved);
    let day = h.store().day(now.div_euclid(DAY)).unwrap().unwrap();
    assert_eq!((day.overruns, day.overrun_micros), (1, actual - reserved));
    // One window charged plus the overrun (about 0.37 of a window): of the
    // 2.63 windows left only two fit.
    admitted(&admit(h, &config, now + 2, &Req::new("y", "b", "run", 0)));
    admitted(&admit(h, &config, now + 2, &Req::new("y2", "b2", "run", 0)));
    assert_eq!(
        refused(&admit(h, &config, now + 3, &Req::new("z", "c", "run", 0))),
        RefusalCode::TrialPaused
    );
    check_month_sums(h);
}

fn replay_returns_the_admission_only_for_the_same_open_request<H: Harness>(h: &mut H) {
    let config = config();
    let now = trial_day();
    let first = admit(h, &config, now, &Req::new("x", "a", "run", 0));
    let replay = admit(h, &config, now + 100, &Req::new("x", "a", "run", 0));
    assert!(matches!(replay, Decision::Admitted { replayed: true, .. }));
    assert_eq!(admitted(&first), admitted(&replay));
    assert_eq!(h.store().month("2027-01").unwrap().unwrap().reservations, 1);
    for changed in [
        Req::new("x", "b", "run", 0),
        Req::new("x", "a", "other", 0),
        Req::new("x", "a", "run", 1),
        Req::new("x", "a", "run", 0).input(10_001),
        Req::new("x", "a", "run", 0).feature(Feature::ChaptersSummary),
    ] {
        let result = h.op(|s| ledger::admit(s, &config, now + 200, &changed.build()));
        assert_eq!(result.unwrap_err(), StoreError::Conflict);
    }
    settle(h, now + 300, "x", usage(1, 1));
    let after =
        h.op(|s| ledger::admit(s, &config, now + 400, &Req::new("x", "a", "run", 0).build()));
    assert_eq!(
        after.unwrap_err(),
        StoreError::Conflict,
        "a final reservation is never forwarded again"
    );
}

fn a_client_always_asking_high_pays_no_more<H: Harness>(h: &mut H) {
    // The reservation depends only on input tokens and the bundle's maximum
    // output; thinking level never enters it. The rewrite test pins that the
    // maximum output stays the bundle's whatever the device asks.
    let config = config();
    let now = trial_day();
    let medium = admitted(&admit(
        h,
        &config,
        now,
        &Req::new("m", "a", "run-m", 0)
            .feature(Feature::ChaptersSummary)
            .max_output(32_768),
    ));
    settle(h, now + 1, "m", usage(100, 32_768));
    let high = admitted(&admit(
        h,
        &config,
        now + 2,
        &Req::new("h", "a", "run-h", 0)
            .feature(Feature::ChaptersSummary)
            .max_output(32_768)
            .budget_ms(299_000),
    ));
    assert_eq!(medium, high);
    settle(h, now + 3, "h", usage(100, 32_768));
    // And it stays inside the unit bound.
    for run in 0..3 {
        let id = format!("hh{run}");
        admitted(&admit(
            h,
            &config,
            now + 10 + run,
            &Req::new(&id, "a", &format!("hh-{run}"), 0)
                .feature(Feature::ChaptersSummary)
                .max_output(32_768)
                .budget_ms(299_000),
        ));
        settle(h, now + 20 + run, &id, usage(100, 32_768));
    }
    assert_eq!(
        refused(&admit(
            h,
            &config,
            now + 30,
            &Req::new("hh9", "a", "hh-9", 0).feature(Feature::ChaptersSummary)
        )),
        RefusalCode::TrialExhausted
    );
}

fn no_price_pauses_and_alerts<H: Harness>(h: &mut H) {
    let config = config();
    let before_any_price = at("2025-06-01T00:00:00Z");
    let result = h
        .op(|s| {
            ledger::admit(
                s,
                &config,
                before_any_price,
                &Req::new("x", "a", "run", 0).build(),
            )
        })
        .unwrap();
    assert!(matches!(
        result.decision,
        Decision::Refused {
            code: RefusalCode::TrialPaused,
            pause: Some(PauseReason::NoPrice),
            ..
        }
    ));
    assert_eq!(result.alerts[0].kind, AlertKind::NoPrice);
}

fn month_paused_follows_remaining_room<H: Harness>(h: &mut H) {
    let mut config = config();
    config.ceiling_micros = 2 * trial_window() + trial_window() / 2;
    let now = trial_day();
    let status = |h: &mut H| {
        h.op(|s| {
            ledger::status(
                s,
                &config,
                now + 10,
                "a",
                Lane::AppAttest,
                MODEL,
                16_384,
                117_000,
            )
        })
        .unwrap()
        .month_paused
    };
    assert!(!status(h));
    admitted(&admit(h, &config, now, &Req::new("a", "a", "run", 0)));
    admitted(&admit(h, &config, now, &Req::new("b", "b", "run", 0)));
    // Half a window left: under one window's constant.
    assert!(status(h));
    assert_eq!(
        refused(&admit(h, &config, now, &Req::new("c", "c", "run", 0))),
        RefusalCode::TrialPaused
    );
    // Settlements free room: no longer paused, though a refusal was recorded.
    settle(h, now + 1, "a", usage(10, 10));
    assert!(!status(h));
}

/// Randomized admissions and settlements against one ceiling, every window
/// reserved at the constant Google's documented limits give (the model's
/// maximum input, the output cap). The proof rests on those limits, not on
/// any premise about tokenization: a reply within them (any input up to the
/// maximum, any output up to the cap) never overruns, so what a month
/// spends (charged plus overrun) never crosses the ceiling. With replies
/// beyond them, the charge alone stays under the ceiling and the gate
/// counts the rest (the overrun alert is the tripwire for that case).
fn ceiling_property<H: Harness>(h: &mut H, within_limits: bool) {
    let mut config = config();
    config.ceiling_micros = 12 * trial_window();
    config.lifetime_units = 1_000;
    let mut rng = Rng(0x5eed_cafe);
    let mut open: Vec<String> = Vec::new();
    let mut paused = 0;
    let mut now = trial_day();
    for step in 0..600 {
        now += rng.below(5_000) as i64;
        if !open.is_empty() && rng.below(3) == 0 {
            let id = open.remove(rng.below(open.len() as u64) as usize);
            let outcome = match rng.below(4) {
                0 => usage(rng.below(MAX_INPUT + 1), rng.below(16_385)),
                1 => SettleOutcome::Rejected { status: 429 },
                2 => SettleOutcome::Ambiguous {
                    class: AmbiguousClass::Status5xx,
                    status: Some(500),
                },
                // Billed at the documented limits exactly.
                _ if within_limits => usage(MAX_INPUT, 16_384),
                _ => usage(MAX_INPUT + 1 + rng.below(200_000), rng.below(16_384)),
            };
            settle(h, now, &id, outcome);
        } else {
            let id = format!("r{step}");
            let subject = format!("install-{}", rng.below(40));
            let req = Req::new(
                &id,
                &subject,
                &format!("run-{}", rng.below(8)),
                rng.below(12) as u16,
            )
            .input(1 + rng.below(30_000));
            match admit(h, &config, now, &req) {
                Decision::Admitted { .. } => open.push(id),
                Decision::Refused {
                    code: RefusalCode::TrialPaused,
                    ..
                } => paused += 1,
                Decision::Refused { .. } => {}
            }
        }
        check_month_sums(h);
        for (key, charged, _) in h.month_sums() {
            assert!(
                charged <= config.ceiling_micros,
                "I2: {charged} at step {step}"
            );
            if within_limits {
                let month = h.store().month(&key).unwrap().unwrap();
                assert_eq!(
                    month.overrun_micros, 0,
                    "a reply within the limits overran at step {step}"
                );
                let spent = month.charged_micros + month.overrun_micros;
                assert!(
                    spent <= config.ceiling_micros,
                    "{spent} spent at step {step}"
                );
            }
        }
    }
    assert!(paused > 0, "the run never reached the ceiling");
}

fn concurrent_admissions_cannot_cross_the_ceiling<H: Harness>(h: &mut H) {
    ceiling_property(h, true);
}

fn reported_overruns_still_keep_the_charge_under_the_ceiling<H: Harness>(h: &mut H) {
    ceiling_property(h, false);
}

fn the_window_constant_covers_any_documented_usage<H: Harness>(h: &mut H) {
    // Room for exactly one window. The count (one above the carousel
    // body's 10,951 bytes) does not enter the reservation.
    let mut config = config();
    config.ceiling_micros = trial_window();
    let now = trial_day();
    let req = |id: &str, subject: &str| Req::new(id, subject, "run", 0).input(10_952);
    assert_eq!(
        admitted(&admit(h, &config, now, &req("x", "a"))),
        trial_window()
    );
    // Billed at both documented limits: still within the reservation.
    match settle(h, now + 1, "x", usage(MAX_INPUT, 16_384)) {
        SettleResult::Settled {
            charged_micros,
            overrun_micros,
            ..
        } => assert_eq!((charged_micros, overrun_micros), (trial_window(), 0)),
        other => panic!("{other:?}"),
    }
    let month = h.store().month("2027-01").unwrap().unwrap();
    assert_eq!(
        month.charged_micros + month.overrun_micros,
        config.ceiling_micros
    );
    // No room for another window's constant, however small its count.
    assert_eq!(
        refused(&admit(h, &config, now + 2, &req("y", "b").input(1))),
        RefusalCode::TrialPaused
    );
    // A count above the model's limit is refused before anything is
    // reserved (the run bound raised so it is not what refuses).
    let mut roomy = config.clone();
    roomy.ceiling_micros = 100 * trial_window();
    roomy.run_max_input_tokens = 2 * MAX_INPUT;
    let before = h.store().month("2027-01").unwrap().unwrap().reservations;
    assert_eq!(
        refused(&admit(
            h,
            &roomy,
            now + 3,
            &req("z", "c").input(MAX_INPUT + 1)
        )),
        RefusalCode::TrialRunBound
    );
    admitted(&admit(h, &roomy, now + 4, &req("w", "d").input(MAX_INPUT)));
    assert_eq!(
        h.store().month("2027-01").unwrap().unwrap().reservations,
        before + 1
    );
    check_month_sums(h);
}

fn a_reservation_stored_below_the_constant_never_replays<H: Harness>(h: &mut H) {
    let mut config = config();
    config.ceiling_micros = 5_000_000;
    let now = trial_day();
    let req = Req::new("legacy", "a", "run", 0).input(10_952);
    admitted(&admit(h, &config, now, &req));
    // An earlier version stored this open reservation at its own, smaller
    // amount (round 2's bytes bound: $0.139307).
    let legacy = 139_307;
    let mut reservation = h.store().reservation("legacy").unwrap().unwrap();
    let excess = reservation.reserved_micros - legacy;
    reservation.reserved_micros = legacy;
    reservation.charged_micros = legacy;
    h.op(|s| s.put_reservation(&reservation)).unwrap();
    let mut month = h.store().month("2027-01").unwrap().unwrap();
    month.charged_micros -= excess;
    h.op(|s| s.put_month(&month)).unwrap();
    check_month_sums(h);
    let before = h.store().month("2027-01").unwrap().unwrap();
    // Its replay is refused (the Worker answers trial_unavailable and
    // forwards nothing); the reservation stays open and expires as usual.
    let replay = h.op(|s| ledger::admit(s, &config, now + 100, &req.build()));
    assert_eq!(replay.unwrap_err(), StoreError::Conflict);
    assert_eq!(h.store().month("2027-01").unwrap().unwrap(), before);
    assert_eq!(
        h.store().reservation("legacy").unwrap().unwrap().state,
        ReservationState::Open
    );
    // A reservation at the constant replays as before.
    admitted(&admit(
        h,
        &config,
        now + 200,
        &Req::new("current", "b", "run", 0),
    ));
    assert!(matches!(
        admit(h, &config, now + 300, &Req::new("current", "b", "run", 0)),
        Decision::Admitted { replayed: true, .. }
    ));
}

/// What status says and what admission does for the same window at `now`.
fn paused_and_refused<H: Harness>(
    h: &mut H,
    config: &LedgerConfig,
    now: i64,
    id: &str,
) -> (bool, bool) {
    let paused = h
        .op(|s| {
            ledger::status(
                s,
                config,
                now,
                "probe",
                Lane::AppAttest,
                MODEL,
                16_384,
                117_000,
            )
        })
        .unwrap()
        .month_paused;
    let refused = matches!(
        admit(h, config, now, &Req::new(id, id, "run", 0)),
        Decision::Refused {
            code: RefusalCode::TrialPaused,
            ..
        }
    );
    (paused, refused)
}

fn month_paused_agrees_with_the_gate_across_a_price_switch<H: Harness>(h: &mut H) {
    let now = trial_day();
    // Prices double one second from now: a window admitted now is priced at
    // the double for its whole lock, and 3,000,000 µ$ does not cover it.
    let mut config = config();
    config.ceiling_micros = 3_000_000;
    config.prices = price_table(&format!(
        r#"[{{"model":"{MODEL}","effective_from":"2027-01-01T00:00:00Z","input_usd_per_million":1.5,"output_usd_per_million":7.5,"max_input_tokens":1048576}},
            {{"model":"{MODEL}","effective_from":"2027-01-15T12:00:01Z","input_usd_per_million":3.0,"output_usd_per_million":15.0,"max_input_tokens":1048576}}]"#
    ))
    .unwrap();
    assert_eq!(paused_and_refused(h, &config, now, "switch"), (true, true));
    // The same switch a day away is outside the lock: both say it fits.
    config.prices = price_table(&format!(
        r#"[{{"model":"{MODEL}","effective_from":"2027-01-01T00:00:00Z","input_usd_per_million":1.5,"output_usd_per_million":7.5,"max_input_tokens":1048576}},
            {{"model":"{MODEL}","effective_from":"2027-01-16T12:00:00Z","input_usd_per_million":3.0,"output_usd_per_million":15.0,"max_input_tokens":1048576}}]"#
    ))
    .unwrap();
    assert_eq!(paused_and_refused(h, &config, now, "later"), (false, false));
}

fn month_paused_agrees_with_the_gate_for_a_full_spill_month<H: Harness>(h: &mut H) {
    let mut config = config();
    config.ceiling_micros = 2 * trial_window() + trial_window() / 2;
    // February is full: two windows, half of one left.
    for id in ["f1", "f2"] {
        admitted(&admit(
            h,
            &config,
            at("2027-02-01T12:00:00Z"),
            &Req::new(id, id, "run", 0),
        ));
    }
    // A window locked past midnight on 31 January reaches into February.
    assert_eq!(
        paused_and_refused(h, &config, at("2027-01-31T23:59:30Z"), "late"),
        (true, true)
    );
    // One whose lock ends in January fits.
    assert_eq!(
        paused_and_refused(h, &config, at("2027-01-31T23:00:00Z"), "early"),
        (false, false)
    );
}

fn a_replay_under_an_edited_price_row_is_refused<H: Harness>(h: &mut H) {
    let table = |input: &str, output: &str| {
        price_table(&format!(
            r#"[{{"model":"{MODEL}","effective_from":"2027-01-01T00:00:00Z","input_usd_per_million":{input},"output_usd_per_million":{output},"max_input_tokens":1000000}}]"#
        ))
        .unwrap()
    };
    let mut config = config();
    config.ceiling_micros = 3_000_000;
    config.prices = table("1", "10");
    let now = trial_day();
    let req = Req::new("x", "a", "run", 0);
    assert_eq!(admitted(&admit(h, &config, now, &req)), 1_163_840);
    // The same dated row edited in place, input up and output down: the
    // constant falls to $1.116384, but the stored rates no longer apply.
    let mut edited = config.clone();
    edited.prices = table("1.1", "1");
    let replay = h.op(|s| ledger::admit(s, &edited, now + 100, &req.build()));
    assert_eq!(replay.unwrap_err(), StoreError::Conflict);
    // Nothing was forwarded for it: it expires charged in full.
    assert_eq!(
        h.op(|s| ledger::expire_due(s, now + 600_000, 10)).unwrap(),
        1
    );
    // A fresh window under the edited row reserves and settles at its rates.
    assert_eq!(
        admitted(&admit(
            h,
            &edited,
            now + 600_001,
            &Req::new("y", "b", "run", 0)
        )),
        1_116_384
    );
    settle(h, now + 600_002, "y", usage(1_000_000, 16_384));
    // What Google bills (y at the edited rates; x was never sent) never
    // exceeds what the ledger charged.
    let billed = cost_micros(1_000_000, 1_100_000) + cost_micros(16_384, 1_000_000);
    let month = h.store().month("2027-01").unwrap().unwrap();
    assert!(billed <= month.charged_micros + month.overrun_micros);
    assert_eq!(month.charged_micros, 1_163_840 + 1_116_384);
    check_month_sums(h);
}

fn an_overflowing_overrun_saturates_and_pauses_instead_of_rolling_back<H: Harness>(h: &mut H) {
    let config = config();
    for (now, key) in [(trial_day(), "2027-01"), (open_day(), "2026-12")] {
        let id = format!("x-{key}");
        let reserved = admitted(&admit(h, &config, now, &Req::new(&id, &id, "run", 0)));
        // A reply reporting more usage than any stored amount can hold.
        let effects = h
            .op(|s| ledger::settle(s, now + 1, &id, &usage(u64::MAX / 2, 1_000)))
            .expect("the settlement persists");
        match effects.result {
            SettleResult::Settled { charged_micros, .. } => assert_eq!(charged_micros, reserved),
            other => panic!("{other:?}"),
        }
        let month = h.store().month(key).unwrap().unwrap();
        assert_eq!(month.overrun_micros, MAX_STORED_INTEGER);
        assert!(month.paused_at.is_some());
        let kinds: Vec<_> = effects.alerts.iter().map(|alert| alert.kind).collect();
        assert!(kinds.contains(&AlertKind::Ceiling), "{kinds:?}");
        assert!(kinds.contains(&AlertKind::Overrun), "{kinds:?}");
        assert_eq!(
            h.store().reservation(&id).unwrap().unwrap().state,
            ReservationState::Settled
        );
        // Every later window that month is refused, in either mode, instead
        // of failing at storage.
        let next = format!("y-{key}");
        assert_eq!(
            refused(&admit(
                h,
                &config,
                now + 2,
                &Req::new(&next, &next, "run", 0)
            )),
            RefusalCode::TrialPaused
        );
    }
    check_month_sums(h);
}

fn an_overrun_alerts_the_day_it_happens<H: Harness>(h: &mut H) {
    let config = config();
    let now = trial_day();
    let settle_effects = |h: &mut H, at: i64, id: &str, outcome: SettleOutcome| {
        h.op(|store| ledger::settle(store, at, id, &outcome))
            .expect("settle")
    };
    let reserved = admitted(&admit(h, &config, now, &Req::new("x", "a", "run", 0)));
    let effects = settle_effects(h, now + 1, "x", beyond_limits());
    let SettleResult::Settled { overrun_micros, .. } = effects.result else {
        panic!("{:?}", effects.result)
    };
    assert!(overrun_micros > 0);
    assert_eq!(effects.alerts.len(), 1);
    let alert = &effects.alerts[0];
    assert_eq!(alert.kind, AlertKind::Overrun);
    assert_eq!(alert.period, format!("d{}", now.div_euclid(DAY)));
    assert_eq!((alert.value_a, alert.value_b), (overrun_micros, reserved));
    // A second overrun that day is counted, not alerted again.
    admitted(&admit(h, &config, now + 2, &Req::new("y", "b", "run", 0)));
    assert!(settle_effects(h, now + 3, "y", beyond_limits())
        .alerts
        .is_empty());
    let day = h.store().day(now.div_euclid(DAY)).unwrap().unwrap();
    assert_eq!(day.overruns, 2);
    // The next UTC day alerts anew; a settlement within its reservation
    // raises nothing.
    admitted(&admit(h, &config, now + DAY, &Req::new("z", "c", "run", 0)));
    let next_day = settle_effects(h, now + DAY + 1, "z", beyond_limits());
    assert_eq!(
        next_day
            .alerts
            .iter()
            .map(|alert| alert.kind)
            .collect::<Vec<_>>(),
        vec![AlertKind::Overrun]
    );
    admitted(&admit(
        h,
        &config,
        now + DAY + 2,
        &Req::new("w", "d", "run", 0),
    ));
    assert!(settle_effects(h, now + DAY + 3, "w", usage(10_000, 16_384))
        .alerts
        .is_empty());
    check_month_sums(h);
}

fn prune_keeps_runs_that_consumed_a_unit<H: Harness>(h: &mut H) {
    let config = config();
    run_once(h, &config, open_day(), "a", "open-run");
    run_once(h, &config, trial_day(), "a", "trial-run");
    admitted(&admit(
        h,
        &config,
        trial_day(),
        &Req::new("ops", "bearer:ops", "ops-run", 0).bearer(),
    ));
    settle(h, trial_day() + 1, "ops", usage(1, 1));
    let later = trial_day() + 200 * DAY;
    h.op(|s| ledger::prune(s, later)).unwrap();
    assert!(h.store().run("a", "open-run").unwrap().is_none());
    assert!(h.store().run("bearer:ops", "ops-run").unwrap().is_none());
    assert!(
        h.store().run("a", "trial-run").unwrap().is_some(),
        "proof the run may resume for free"
    );
    assert!(h.store().reservation("a-trial-run").unwrap().is_none());
    assert!(h.store().install("a").unwrap().is_some());
    assert!(h.store().month("2027-01").unwrap().is_some());
}

fn provider_failure_alert_bursty_not_sparse<H: Harness>(h: &mut H) {
    let config = config();
    let now = trial_day();
    let fail = SettleOutcome::Ambiguous {
        class: AmbiguousClass::Status5xx,
        status: Some(503),
    };
    // Sparse: 4 failures among 40 forwards over six hours raises nothing.
    let mut alerts = 0;
    for n in 0..40 {
        let id = format!("s{n}");
        let subject = format!("sparse-{n}");
        admitted(&admit(
            h,
            &config,
            now + n * 500_000,
            &Req::new(&id, &subject, "run", 0),
        ));
        let outcome = if n % 10 == 0 { fail } else { usage(10, 10) };
        alerts += h
            .op(|s| ledger::settle(s, now + n * 500_000 + 1, &id, &outcome))
            .unwrap()
            .alerts
            .len();
    }
    assert_eq!(alerts, 0);
    // A burst of five failures inside a minute, a day later, raises one.
    let burst = now + 2 * DAY;
    for n in 0..8 {
        let id = format!("b{n}");
        let subject = format!("burst-{n}");
        admitted(&admit(
            h,
            &config,
            burst + n * 5_000,
            &Req::new(&id, &subject, "run", 0),
        ));
        alerts += h
            .op(|s| ledger::settle(s, burst + n * 5_000 + 1, &id, &fail))
            .unwrap()
            .alerts
            .len();
    }
    assert_eq!(alerts, 1, "five failures alert once per six-hour window");
    // Expiries are not provider failures.
    assert_eq!(
        h.store()
            .day(burst.div_euclid(DAY))
            .unwrap()
            .unwrap()
            .provider_failures,
        8
    );
}

fn mirror_failures_alert_on_the_fifth<H: Harness>(h: &mut H) {
    let now = trial_day();
    let mut raised = Vec::new();
    for _ in 0..6 {
        let (count, alert) = h
            .op(|s| ledger::record_mirror_flush(s, now, false))
            .unwrap();
        raised.push((count, alert.is_some()));
    }
    assert_eq!(
        raised,
        vec![
            (1, false),
            (2, false),
            (3, false),
            (4, false),
            (5, true),
            (6, false)
        ]
    );
    assert_eq!(
        h.op(|s| ledger::record_mirror_flush(s, now, true)).unwrap(),
        (0, None)
    );
    let pending = h.op(|s| ledger::alerts_to_send(s)).unwrap();
    assert_eq!(pending.len(), 1);
    // Each attempt is claimed before its send; five claims, then it stops.
    let period = pending[0].period.clone();
    for attempt in 1..=5 {
        let claimed = h
            .op(|s| ledger::claim_alert_attempt(s, AlertKind::Mirror, &period))
            .unwrap()
            .expect("claimable");
        assert_eq!(claimed.attempts, attempt);
    }
    assert!(h
        .op(|s| ledger::claim_alert_attempt(s, AlertKind::Mirror, &period))
        .unwrap()
        .is_none());
    assert!(
        h.op(|s| ledger::alerts_to_send(s)).unwrap().is_empty(),
        "five attempts, then it stops"
    );
    // A sent alert is never claimed again.
    for _ in 0..5 {
        h.op(|s| ledger::record_mirror_flush(s, now + DAY, false))
            .unwrap();
    }
    let next_day = format!("d{}", (now + DAY).div_euclid(DAY));
    h.op(|s| ledger::claim_alert_attempt(s, AlertKind::Mirror, &next_day))
        .unwrap()
        .expect("claimable");
    h.op(|s| ledger::mark_alert_sent(s, AlertKind::Mirror, &next_day))
        .unwrap();
    assert!(h
        .op(|s| ledger::claim_alert_attempt(s, AlertKind::Mirror, &next_day))
        .unwrap()
        .is_none());
}

fn day_summaries_are_taken_once<H: Harness>(h: &mut H) {
    let config = config();
    run_once(h, &config, open_day(), "a", "r1");
    run_once(h, &config, open_day() + DAY, "b", "r1");
    let days = h
        .op(|s| ledger::take_day_summaries(s, open_day() + 2 * DAY))
        .unwrap();
    assert_eq!(days.len(), 2);
    assert!(h
        .op(|s| ledger::take_day_summaries(s, open_day() + 2 * DAY))
        .unwrap()
        .is_empty());
    let next = h.op(|s| ledger::next_alarm(s, open_day())).unwrap();
    assert_eq!(next, open_day() + HOUR);
}

#[test]
fn a_failing_statement_rolls_the_whole_operation_back() {
    let config = config();
    let now = trial_day();
    let mut h = Sql::new();
    run_once(&mut h, &config, now, "a", "warm");
    // Count the statements each operation runs.
    let start = h.0.backend().executed.get();
    let probe_req = Req::new("probe", "b", "run", 0);
    h.op(|s| ledger::admit(s, &config, now + 1, &probe_req.build()))
        .unwrap();
    let admit_statements = h.0.backend().executed.get() - start;
    let start = h.0.backend().executed.get();
    h.op(|s| ledger::settle(s, now + 2, "probe", &usage(10, 10)))
        .unwrap();
    let settle_statements = h.0.backend().executed.get() - start;
    assert!(admit_statements > 10 && settle_statements > 5);
    // Fail each statement of a fresh admission and settlement in turn: the
    // store is left exactly as it was.
    for k in 0..admit_statements {
        let before = h.dump();
        let base = h.0.backend().executed.get();
        h.0.backend().fail_at.set(Some(base + k));
        let req = Req::new(&format!("f{k}"), "c", &format!("run-{k}"), 0);
        assert!(h
            .op(|s| ledger::admit(s, &config, now + 10, &req.build()))
            .is_err());
        h.0.backend().fail_at.set(None);
        assert_eq!(h.dump(), before, "admit statement {k}");
    }
    let id = "settle-me";
    admitted(&admit(
        &mut h,
        &config,
        now + 20,
        &Req::new(id, "d", "run", 0),
    ));
    for k in 0..settle_statements {
        let before = h.dump();
        let base = h.0.backend().executed.get();
        h.0.backend().fail_at.set(Some(base + k));
        assert!(h
            .op(|s| ledger::settle(s, now + 21, id, &usage(10, 10)))
            .is_err());
        h.0.backend().fail_at.set(None);
        assert_eq!(h.dump(), before, "settle statement {k}");
    }
    assert!(matches!(
        settle(&mut h, now + 22, id, usage(10, 10)),
        SettleResult::Settled { .. }
    ));
}

#[test]
fn both_stores_reach_the_same_state() {
    let config = config();
    let mut mem = Mem(MemoryStore::default());
    let mut sql = Sql::new();
    let mut rng = Rng(42);
    let mut now = trial_day();
    let mut open = Vec::new();
    for step in 0..200 {
        now += rng.below(3_000) as i64;
        if !open.is_empty() && rng.below(2) == 0 {
            let id: String = open.remove(0);
            let outcome = usage(rng.below(9_000), rng.below(9_000));
            assert_eq!(
                settle(&mut mem, now, &id, outcome),
                settle(&mut sql, now, &id, outcome)
            );
        } else {
            let id = format!("r{step}");
            let req = Req::new(
                &id,
                &format!("s{}", rng.below(10)),
                &format!("run{}", rng.below(4)),
                rng.below(3) as u16,
            );
            let left = admit(&mut mem, &config, now, &req);
            let right = admit(&mut sql, &config, now, &req);
            assert_eq!(left, right, "step {step}");
            if matches!(left, Decision::Admitted { .. }) {
                open.push(id);
            }
        }
    }
    let mut months_mem: Vec<_> = mem.month_sums();
    let mut months_sql: Vec<_> = sql.month_sums();
    months_mem.sort();
    months_sql.sort();
    assert_eq!(months_mem, months_sql);
}
