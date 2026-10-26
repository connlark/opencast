//! Worker vars → the ledger's bounds and the price table. Every var is
//! required on every lane; a bad or missing one refuses every request with
//! a logged config error naming the var (never its value).

use opencast_app_attest_core::challenge_limits::challenge_source_hash_key_for_environment;
use serde::Deserialize;

use crate::bundle::{valid_model_id, TrialBundle};
use crate::clock::parse_utc_timestamp_ms;

pub type Micros = u64;
pub const MICROS_PER_USD: u64 = 1_000_000;
/// The largest integer the ledger stores (a JavaScript number is exact to
/// 2⁵³): every count and amount must fit.
pub const MAX_STORED_INTEGER: u64 = 1 << 53;
/// The largest `max_input_tokens` a price row may name: far above any
/// documented context window (gemini-3.8-flash: 1,048,576).
pub const MAX_SUPPORTED_INPUT_TOKENS: u64 = 100_000_000;
/// Price-table sanity bound: no Gemini model costs this much per million.
const MAX_USD_PER_MILLION: f64 = 1_000.0;
const MAX_CEILING_USD: u64 = 10_000;

/// Reads a var by name; the Worker's `Env` in production, a map in tests.
pub trait VarSource {
    fn var(&self, name: &str) -> Option<String>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConfigField {
    AppleTeamId,
    AppleBundleId,
    AppAttestEnvironment,
    TrialProxyEnabled,
    TrialAlertLane,
    TrialModeStartsAt,
    TrialLifetimeUnits,
    TrialMonthlyCeilingUsd,
    TrialPriceTable,
    TrialRunMaxWindows,
    TrialRunMaxInputTokens,
    TrialBodyMaxBytes,
    TrialOpenDailyRequests,
    TrialOpenDailyInputTokens,
    TrialBearerDailyRequests,
    TrialBearerDailyInputTokens,
    Bundle,
    GeminiApiKey,
    TrialBearerToken,
    ChallengeSourceHashKey,
}

impl ConfigField {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::AppleTeamId => "APPLE_TEAM_ID",
            Self::AppleBundleId => "APPLE_BUNDLE_ID",
            Self::AppAttestEnvironment => "APP_ATTEST_ENVIRONMENT",
            Self::TrialProxyEnabled => "TRIAL_PROXY_ENABLED",
            Self::TrialAlertLane => "TRIAL_ALERT_LANE",
            Self::TrialModeStartsAt => "TRIAL_MODE_STARTS_AT",
            Self::TrialLifetimeUnits => "TRIAL_LIFETIME_UNITS",
            Self::TrialMonthlyCeilingUsd => "TRIAL_MONTHLY_CEILING_USD",
            Self::TrialPriceTable => "TRIAL_PRICE_TABLE",
            Self::TrialRunMaxWindows => "TRIAL_RUN_MAX_WINDOWS",
            Self::TrialRunMaxInputTokens => "TRIAL_RUN_MAX_INPUT_TOKENS",
            Self::TrialBodyMaxBytes => "TRIAL_BODY_MAX_BYTES",
            Self::TrialOpenDailyRequests => "TRIAL_OPEN_DAILY_REQUESTS",
            Self::TrialOpenDailyInputTokens => "TRIAL_OPEN_DAILY_INPUT_TOKENS",
            Self::TrialBearerDailyRequests => "TRIAL_BEARER_DAILY_REQUESTS",
            Self::TrialBearerDailyInputTokens => "TRIAL_BEARER_DAILY_INPUT_TOKENS",
            Self::Bundle => "embedded_bundle",
            Self::GeminiApiKey => "GEMINI_API_KEY",
            Self::TrialBearerToken => "TRIAL_BEARER_TOKEN",
            Self::ChallengeSourceHashKey => "CHALLENGE_SOURCE_HASH_KEY",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConfigReason {
    Missing,
    Invalid,
    /// `TRIAL_LIFETIME_UNITS` differs from the embedded bundle's.
    BundleMismatch,
    /// The worst month's amounts (the daily caps × 31 × the largest
    /// window, plus a spill month) would not fit the stored integers.
    MonthOutOfRange,
    Bundle(&'static str),
}

impl ConfigReason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Missing => "missing",
            Self::Invalid => "invalid",
            Self::BundleMismatch => "bundle_mismatch",
            Self::MonthOutOfRange => "month_out_of_range",
            Self::Bundle(reason) => reason,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ConfigError {
    pub field: ConfigField,
    pub reason: ConfigReason,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AlertLane {
    Dev,
    ProdStaging,
    Production,
}

impl AlertLane {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Dev => "dev",
            Self::ProdStaging => "prod-staging",
            Self::Production => "production",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PriceRow {
    pub model: String,
    pub effective_from_ms: i64,
    /// Micro-dollars per million tokens (= dollars per million × 10⁶).
    pub input_micros_per_million: u64,
    pub output_micros_per_million: u64,
    /// The model's documented maximum input (its context window): Google
    /// rejects, unbilled, a prompt above it.
    pub max_input_tokens: u64,
}

/// What a reservation is priced on: the highest of each over its interval.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Pricing {
    pub input_micros_per_million: u64,
    pub output_micros_per_million: u64,
    pub max_input_tokens: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PriceTable {
    rows: Vec<PriceRow>,
}

impl PriceTable {
    pub fn new(mut rows: Vec<PriceRow>) -> Self {
        rows.sort_by(|left, right| {
            (left.model.as_str(), left.effective_from_ms)
                .cmp(&(right.model.as_str(), right.effective_from_ms))
        });
        Self { rows }
    }

    /// The row in force for `model` at `now_ms`: the latest `effective_from`
    /// not after it.
    pub fn at(&self, model: &str, now_ms: i64) -> Option<&PriceRow> {
        self.rows
            .iter()
            .filter(|row| row.model == model && row.effective_from_ms <= now_ms)
            .max_by_key(|row| row.effective_from_ms)
    }

    /// The highest input price, output price and input limit among
    /// `model`'s rows: the most any reservation for it can combine.
    fn maxima(&self, model: &str) -> Pricing {
        let rows = self.rows.iter().filter(|row| row.model == model);
        Pricing {
            input_micros_per_million: rows
                .clone()
                .map(|row| row.input_micros_per_million)
                .max()
                .unwrap_or(0),
            output_micros_per_million: rows
                .clone()
                .map(|row| row.output_micros_per_million)
                .max()
                .unwrap_or(0),
            max_input_tokens: rows.map(|row| row.max_input_tokens).max().unwrap_or(0),
        }
    }

    /// The largest reservation any window can hold under this table with an
    /// output cap of `max_output_tokens`.
    pub fn largest_window(&self, max_output_tokens: u32) -> Micros {
        self.rows
            .iter()
            .map(|row| {
                let maxima = self.maxima(&row.model);
                cost_micros(maxima.max_input_tokens, maxima.input_micros_per_million)
                    .saturating_add(cost_micros(
                        u64::from(max_output_tokens),
                        maxima.output_micros_per_million,
                    ))
            })
            .max()
            .unwrap_or(0)
    }

    /// The highest input price, output price and maximum input in force at
    /// any instant of `[from_ms, to_ms]`: a window admitted before a price
    /// change may be billed after it. `None` when no row is in force at
    /// `from_ms`.
    pub fn max_over(&self, model: &str, from_ms: i64, to_ms: i64) -> Option<Pricing> {
        let first = self.at(model, from_ms)?;
        let later = self.rows.iter().filter(|row| {
            row.model == model && row.effective_from_ms > from_ms && row.effective_from_ms <= to_ms
        });
        Some(later.fold(
            Pricing {
                input_micros_per_million: first.input_micros_per_million,
                output_micros_per_million: first.output_micros_per_million,
                max_input_tokens: first.max_input_tokens,
            },
            |pricing, row| {
                Pricing {
                    input_micros_per_million: pricing
                        .input_micros_per_million
                        .max(row.input_micros_per_million),
                    output_micros_per_million: pricing
                        .output_micros_per_million
                        .max(row.output_micros_per_million),
                    max_input_tokens: pricing.max_input_tokens.max(row.max_input_tokens),
                }
            },
        ))
    }
}

/// Bounds and prices the accounting object admits against.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LedgerConfig {
    pub mode_starts_at_ms: i64,
    pub lifetime_units: u32,
    pub ceiling_micros: Micros,
    pub run_max_windows: u32,
    pub run_max_input_tokens: u64,
    pub open_daily_requests: u64,
    pub open_daily_input_tokens: u64,
    pub bearer_daily_requests: u64,
    pub bearer_daily_input_tokens: u64,
    pub prices: PriceTable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    Open,
    Trial,
}

impl Mode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Open => "open",
            Self::Trial => "trial",
        }
    }
}

impl LedgerConfig {
    /// Trial mode (lifetime units and the monthly ceiling) from
    /// `TRIAL_MODE_STARTS_AT` on; the daily backstop before it.
    pub fn mode_at(&self, now_ms: i64) -> Mode {
        if now_ms >= self.mode_starts_at_ms {
            Mode::Trial
        } else {
            Mode::Open
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrialConfig {
    pub app_id: String,
    pub app_attest_environment: String,
    pub enabled: bool,
    pub alert_lane: AlertLane,
    pub mode_starts_at: String,
    pub body_max_bytes: usize,
    pub ledger: LedgerConfig,
}

impl TrialConfig {
    /// The envelope carries the payload as a JSON string; escaping JSON text
    /// at most doubles it, plus room for the ids and the assertion.
    pub fn envelope_max_bytes(&self) -> usize {
        self.body_max_bytes
            .saturating_mul(2)
            .saturating_add(16 * 1024)
    }
}

/// Whether the kill switch is on; read before anything else so a lane can be
/// switched off even when another var is broken.
pub fn enabled(vars: &impl VarSource) -> bool {
    vars.var(ConfigField::TrialProxyEnabled.as_str()).as_deref() == Some("true")
}

pub fn load(vars: &impl VarSource, bundle: &TrialBundle) -> Result<TrialConfig, ConfigError> {
    let team_id = text(vars, ConfigField::AppleTeamId)?;
    let bundle_id = text(vars, ConfigField::AppleBundleId)?;
    let environment = text(vars, ConfigField::AppAttestEnvironment)?;
    if !matches!(environment.as_str(), "development" | "production") {
        return Err(invalid(ConfigField::AppAttestEnvironment));
    }
    let enabled = match text(vars, ConfigField::TrialProxyEnabled)?.as_str() {
        "true" => true,
        "false" => false,
        _ => return Err(invalid(ConfigField::TrialProxyEnabled)),
    };
    let alert_lane = match text(vars, ConfigField::TrialAlertLane)?.as_str() {
        "dev" => AlertLane::Dev,
        "prod-staging" => AlertLane::ProdStaging,
        "production" => AlertLane::Production,
        _ => return Err(invalid(ConfigField::TrialAlertLane)),
    };
    let mode_starts_at = text(vars, ConfigField::TrialModeStartsAt)?;
    let mode_starts_at_ms =
        parse_utc_timestamp_ms(&mode_starts_at).ok_or(invalid(ConfigField::TrialModeStartsAt))?;
    let lifetime_units = number(vars, ConfigField::TrialLifetimeUnits, 1, 1_000)? as u32;
    if lifetime_units != bundle.lifetime_units {
        return Err(ConfigError {
            field: ConfigField::TrialLifetimeUnits,
            reason: ConfigReason::BundleMismatch,
        });
    }
    let ceiling_micros = usd_micros(&text(vars, ConfigField::TrialMonthlyCeilingUsd)?)
        .filter(|micros| (1..=MAX_CEILING_USD * MICROS_PER_USD).contains(micros))
        .ok_or(invalid(ConfigField::TrialMonthlyCeilingUsd))?;
    let prices = price_table(&text(vars, ConfigField::TrialPriceTable)?)
        .ok_or(invalid(ConfigField::TrialPriceTable))?;
    let open_daily_requests = number(vars, ConfigField::TrialOpenDailyRequests, 1, 1_000_000)?;
    let bearer_daily_requests = number(vars, ConfigField::TrialBearerDailyRequests, 1, 1_000_000)?;
    // The worst month must fit the ledger's integers: 31 days of the larger
    // daily request cap, each window at the table's largest reservation (or
    // the ceiling, if larger), plus the same again for a spill month.
    let largest_window = prices.largest_window(
        bundle
            .ad_detection
            .max_output_tokens
            .max(bundle.chapters_summary.max_output_tokens),
    );
    let worst_month = open_daily_requests
        .max(bearer_daily_requests)
        .saturating_mul(31)
        .saturating_mul(largest_window)
        .max(ceiling_micros);
    if worst_month.saturating_mul(2) >= MAX_STORED_INTEGER {
        return Err(ConfigError {
            field: ConfigField::TrialPriceTable,
            reason: ConfigReason::MonthOutOfRange,
        });
    }
    Ok(TrialConfig {
        app_id: format!("{team_id}.{bundle_id}"),
        app_attest_environment: environment,
        enabled,
        alert_lane,
        mode_starts_at,
        body_max_bytes: number(vars, ConfigField::TrialBodyMaxBytes, 1_024, 8 * 1024 * 1024)?
            as usize,
        ledger: LedgerConfig {
            mode_starts_at_ms,
            lifetime_units,
            ceiling_micros,
            run_max_windows: number(vars, ConfigField::TrialRunMaxWindows, 1, 1_024)? as u32,
            run_max_input_tokens: number(vars, ConfigField::TrialRunMaxInputTokens, 1, 10_000_000)?,
            open_daily_requests,
            open_daily_input_tokens: number(
                vars,
                ConfigField::TrialOpenDailyInputTokens,
                1,
                10_000_000_000,
            )?,
            bearer_daily_requests,
            bearer_daily_input_tokens: number(
                vars,
                ConfigField::TrialBearerDailyInputTokens,
                1,
                10_000_000_000,
            )?,
            prices,
        },
    })
}

fn invalid(field: ConfigField) -> ConfigError {
    ConfigError {
        field,
        reason: ConfigReason::Invalid,
    }
}

fn text(vars: &impl VarSource, field: ConfigField) -> Result<String, ConfigError> {
    match vars.var(field.as_str()) {
        Some(value) if !value.trim().is_empty() => Ok(value.trim().to_string()),
        _ => Err(ConfigError {
            field,
            reason: ConfigReason::Missing,
        }),
    }
}

fn number(
    vars: &impl VarSource,
    field: ConfigField,
    min: u64,
    max: u64,
) -> Result<u64, ConfigError> {
    let value = text(vars, field)?;
    if !value.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(invalid(field));
    }
    value
        .parse::<u64>()
        .ok()
        .filter(|number| (min..=max).contains(number))
        .ok_or(invalid(field))
}

/// A decimal dollar amount (`50`, `49.5`, at most six decimals) as integer
/// micro-dollars, without floating point.
pub fn usd_micros(value: &str) -> Option<Micros> {
    let (whole, fraction) = value.split_once('.').unwrap_or((value, ""));
    if whole.is_empty()
        || whole.len() > 9
        || fraction.len() > 6
        || !whole.bytes().all(|byte| byte.is_ascii_digit())
        || !fraction.bytes().all(|byte| byte.is_ascii_digit())
        || (value.contains('.') && fraction.is_empty())
    {
        return None;
    }
    let whole: u64 = whole.parse().ok()?;
    let fraction: u64 = format!("{fraction:0<6}").parse().ok()?;
    whole.checked_mul(MICROS_PER_USD)?.checked_add(fraction)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawPriceRow {
    model: String,
    effective_from: String,
    input_usd_per_million: f64,
    output_usd_per_million: f64,
    max_input_tokens: u64,
}

/// `TRIAL_PRICE_TABLE`: a JSON array of dated rows. Both prices must be
/// positive (a zero price would make a reservation free) and exact to the
/// micro-dollar per million; every row carries the model's documented
/// maximum input (positive, at most `MAX_SUPPORTED_INPUT_TOKENS`); the
/// largest reservation the rows of a model can combine into (its largest
/// limit at its highest input price, the largest output cap at its highest
/// output price) fits storage; no two rows share a model and date.
pub fn price_table(json: &str) -> Option<PriceTable> {
    let raw: Vec<RawPriceRow> = serde_json::from_str(json).ok()?;
    if raw.is_empty() {
        return None;
    }
    let mut rows = Vec::with_capacity(raw.len());
    for row in raw {
        if !valid_model_id(&row.model) || row.max_input_tokens == 0 {
            return None;
        }
        rows.push(PriceRow {
            effective_from_ms: parse_utc_timestamp_ms(&row.effective_from)?,
            input_micros_per_million: per_million_micros(row.input_usd_per_million)?,
            output_micros_per_million: per_million_micros(row.output_usd_per_million)?,
            max_input_tokens: row.max_input_tokens,
            model: row.model,
        });
    }
    let table = PriceTable::new(rows);
    let duplicate = table.rows.windows(2).any(|pair| {
        pair[0].model == pair[1].model && pair[0].effective_from_ms == pair[1].effective_from_ms
    });
    // A reservation takes each maximum over its interval, possibly from
    // different rows of the model: the combination must fit.
    let fits = table.rows.iter().all(|row| {
        let maxima = table.maxima(&row.model);
        price_row_fits(&PriceRow {
            model: row.model.clone(),
            effective_from_ms: row.effective_from_ms,
            input_micros_per_million: maxima.input_micros_per_million,
            output_micros_per_million: maxima.output_micros_per_million,
            max_input_tokens: maxima.max_input_tokens,
        })
    });
    (!duplicate && fits).then_some(table)
}

fn per_million_micros(usd: f64) -> Option<u64> {
    if !usd.is_finite() || usd <= 0.0 || usd > MAX_USD_PER_MILLION {
        return None;
    }
    let micros = usd * MICROS_PER_USD as f64;
    let rounded = micros.round();
    ((micros - rounded).abs() < 1e-3 && rounded >= 1.0).then_some(rounded as u64)
}

/// `ceil(tokens × micros_per_million / 10⁶)` without overflow.
/// The key the challenge route hashes client addresses with: the configured
/// secret, or outside production the development fallback. A blank secret
/// is a configuration error, as a missing one is wherever there is no
/// fallback.
pub fn challenge_source_key(
    secret: Option<&str>,
    environment: &str,
    development_key: &str,
) -> Result<String, ConfigReason> {
    if secret.is_some_and(|secret| secret.trim().is_empty()) {
        return Err(ConfigReason::Invalid);
    }
    challenge_source_hash_key_for_environment(secret, environment, development_key)
        .ok_or(ConfigReason::Missing)
}

/// Whether a row's largest reservation fits storage: its input limit at its
/// input price plus the largest possible output cap at its output price.
pub fn price_row_fits(row: &PriceRow) -> bool {
    row.max_input_tokens <= MAX_SUPPORTED_INPUT_TOKENS
        && cost_micros(row.max_input_tokens, row.input_micros_per_million).saturating_add(
            cost_micros(u64::from(u32::MAX), row.output_micros_per_million),
        ) <= MAX_STORED_INTEGER
}

pub fn cost_micros(tokens: u64, micros_per_million: u64) -> Micros {
    let product = u128::from(tokens) * u128::from(micros_per_million);
    let micros = product.div_ceil(1_000_000);
    u64::try_from(micros).unwrap_or(u64::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dollar_amounts_parse_exactly() {
        assert_eq!(usd_micros("50"), Some(50_000_000));
        assert_eq!(usd_micros("49.5"), Some(49_500_000));
        assert_eq!(usd_micros("0.000001"), Some(1));
        for invalid in ["", "50.", ".5", "-1", "1e3", "50.0000001", "5 0", "fifty"] {
            assert_eq!(usd_micros(invalid), None, "{invalid}");
        }
    }

    fn row(effective_from: &str, input: f64, output: f64) -> serde_json::Value {
        serde_json::json!({
            "model": "gemini-3.8-flash",
            "effective_from": effective_from,
            "input_usd_per_million": input,
            "output_usd_per_million": output,
            "max_input_tokens": 1_048_576,
        })
    }

    fn table(rows: &[serde_json::Value]) -> String {
        serde_json::Value::Array(rows.to_vec()).to_string()
    }

    #[test]
    fn the_seeded_gemini_prices_switch_at_2027() {
        let table = price_table(&table(&[
            row("2026-01-01T00:00:00Z", 0.75, 3.75),
            row("2027-01-01T00:00:00Z", 1.5, 7.5),
        ]))
        .expect("seed table parses");
        let flip = parse_utc_timestamp_ms("2027-01-01T00:00:00Z").unwrap();
        let before = table.at("gemini-3.8-flash", flip - 1).unwrap();
        assert_eq!(
            (
                before.input_micros_per_million,
                before.output_micros_per_million
            ),
            (750_000, 3_750_000)
        );
        let after = table.at("gemini-3.8-flash", flip).unwrap();
        assert_eq!(
            (
                after.input_micros_per_million,
                after.output_micros_per_million
            ),
            (1_500_000, 7_500_000)
        );
        assert!(table
            .at(
                "gemini-3.8-flash",
                parse_utc_timestamp_ms("2025-12-31T23:59:59Z").unwrap()
            )
            .is_none());
        assert!(table.at("gemini-3.5-flash", flip).is_none());
        // A window admitted a minute before the switch reserves at the new
        // price; one wholly before it at the old.
        let pricing = |input, output| Pricing {
            input_micros_per_million: input,
            output_micros_per_million: output,
            max_input_tokens: 1_048_576,
        };
        assert_eq!(
            table.max_over("gemini-3.8-flash", flip - 60_000, flip + 120_000),
            Some(pricing(1_500_000, 7_500_000))
        );
        assert_eq!(
            table.max_over("gemini-3.8-flash", flip - 600_000, flip - 1),
            Some(pricing(750_000, 3_750_000))
        );
    }

    #[test]
    fn bad_price_tables_are_refused() {
        let mut extra_field = row("2026-01-01T00:00:00Z", 0.75, 3.75);
        extra_field["x"] = 1.into();
        let mut no_limit = row("2026-01-01T00:00:00Z", 0.75, 3.75);
        no_limit.as_object_mut().unwrap().remove("max_input_tokens");
        let mut zero_limit = row("2026-01-01T00:00:00Z", 0.75, 3.75);
        zero_limit["max_input_tokens"] = 0.into();
        for invalid in [
            table(&[no_limit]),
            table(&[zero_limit]),
            "[]".to_string(),
            "{}".to_string(),
            table(&[row("2026-01-01T00:00:00Z", 0.0, 3.75)]),
            table(&[row("2026-01-01", 0.75, 3.75)]),
            table(&[extra_field]),
            table(&[row("2026-01-01T00:00:00Z", 0.000_000_1, 3.75)]),
            table(&[
                row("2026-01-01T00:00:00Z", 0.75, 3.75),
                row("2026-01-01T00:00:00Z", 1.0, 4.0),
            ]),
        ] {
            assert!(price_table(&invalid).is_none(), "{invalid}");
        }
    }

    #[test]
    fn cost_rounds_up_to_the_micro_dollar() {
        assert_eq!(cost_micros(0, 750_000), 0);
        assert_eq!(cost_micros(1, 750_000), 1);
        assert_eq!(cost_micros(2_039, 750_000), 1_530);
        assert_eq!(cost_micros(400_000, 1_500_000), 600_000);
        assert_eq!(cost_micros(u64::MAX, u64::MAX), u64::MAX);
    }
}
