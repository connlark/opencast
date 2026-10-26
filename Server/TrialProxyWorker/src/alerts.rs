//! Pushover alert text: fixed templates, numbers and the lane only.

use crate::config::{AlertLane, MICROS_PER_USD};
use crate::ledger::{AlertKind, AlertRecord};

pub const PUSHOVER_URL: &str = "https://api.pushover.net/1/messages.json";

fn dollars(micros: u64) -> String {
    format!(
        "${}.{:02}",
        micros / MICROS_PER_USD,
        (micros % MICROS_PER_USD) / 10_000
    )
}

/// Every micro-dollar: an overrun can be smaller than a cent.
fn exact_dollars(micros: u64) -> String {
    format!(
        "${}.{:06}",
        micros / MICROS_PER_USD,
        micros % MICROS_PER_USD
    )
}

pub fn title(lane: AlertLane) -> String {
    format!("opencast trial proxy ({})", lane.as_str())
}

pub fn message(alert: &AlertRecord) -> String {
    match alert.kind {
        AlertKind::Ceiling => format!(
            "Monthly ceiling reached for {}: {} of {} charged. New trial windows are paused until the month ends.",
            alert.period,
            dollars(alert.value_a),
            dollars(alert.value_b)
        ),
        AlertKind::Backstop => format!(
            "Daily backstop reached ({}): {} windows, {} counted input tokens admitted today. New windows are paused until UTC midnight.",
            alert.period, alert.value_a, alert.value_b
        ),
        AlertKind::NoPrice => format!(
            "The trial model has no effective price ({}). Every window is refused until TRIAL_PRICE_TABLE covers it.",
            alert.period
        ),
        AlertKind::ProviderFailures => format!(
            "Provider failures: {} of {} forwards in the last six hours were 5xx, timeouts or unreachable.",
            alert.value_a, alert.value_b
        ),
        AlertKind::Mirror => format!(
            "The D1 mirror has failed {} flushes in a row; the object's own counters are unaffected.",
            alert.value_a
        ),
        AlertKind::Overrun => format!(
            "A settlement reported {} beyond its {} reservation ({}). Reservations rest on the model's documented limits, so check max_input_tokens, the output cap and TRIAL_PRICE_TABLE; the ceiling gate counts the excess.",
            exact_dollars(alert.value_a),
            exact_dollars(alert.value_b),
            alert.period
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn templates_quote_only_numbers_and_periods() {
        let alert = AlertRecord {
            kind: AlertKind::Ceiling,
            period: "2027-01".into(),
            sent: false,
            attempts: 0,
            value_a: 49_731_250,
            value_b: 50_000_000,
            created_at: 0,
        };
        assert_eq!(
            message(&alert),
            "Monthly ceiling reached for 2027-01: $49.73 of $50.00 charged. New trial windows are paused until the month ends."
        );
        assert_eq!(
            title(AlertLane::ProdStaging),
            "opencast trial proxy (prod-staging)"
        );
    }
}
