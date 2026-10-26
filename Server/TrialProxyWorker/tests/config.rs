//! The embedded bundle equals the checked-in file it came from, and every
//! lane's wrangler config loads, agrees with the bundle and carries the
//! bindings the worker reads. A checkout may carry the deployed
//! `wrangler.toml`, the public `wrangler.example.toml`, or both; each one
//! present is checked, the template for its fail-closed posture.

use std::collections::BTreeMap;
use std::path::Path;

use opencast_trial_proxy_worker::bundle::{
    embedded, parse_bundle, EMBEDDED_BUNDLE_FILE, GOOGLE_HOST,
};
use opencast_trial_proxy_worker::config::{load, AlertLane, VarSource};
use serde_json::Value;

const MANIFESTS: &str = "../ModelGatewayWorker/manifests/analysis-policy";

fn highest_manifest() -> (String, String) {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join(MANIFESTS);
    let (version, name) = std::fs::read_dir(&dir)
        .unwrap()
        .filter_map(|entry| {
            let name = entry.ok()?.file_name().into_string().ok()?;
            let version: u64 = name
                .strip_prefix('v')?
                .strip_suffix(".json")?
                .parse()
                .ok()?;
            Some((version, name))
        })
        .max()
        .expect("a bundle");
    assert!(version >= 2);
    let text = std::fs::read_to_string(dir.join(&name)).unwrap();
    (name, text)
}

#[test]
fn the_embedded_trial_entries_equal_the_checked_in_bundle() {
    let (name, text) = highest_manifest();
    assert_eq!(
        EMBEDDED_BUNDLE_FILE, name,
        "build.rs embeds the highest vN.json"
    );
    let embedded = embedded().unwrap();
    assert_eq!(&parse_bundle(&text).unwrap(), embedded);
    // Read the file independently of the worker's reader.
    let raw: Value = serde_json::from_str(&text).unwrap();
    let model = raw["trial"]["model"].as_str().unwrap();
    assert_eq!(embedded.model, model);
    assert_eq!(
        embedded.starts_at,
        raw["trial"]["starts_at"].as_str().unwrap()
    );
    assert_eq!(
        u64::from(embedded.lifetime_units),
        raw["trial"]["lifetime_units"].as_u64().unwrap()
    );
    for (feature, list, entry) in [
        ("ad_detection", "qualified_models", &embedded.ad_detection),
        (
            "chapters_summary",
            "allowed_models",
            &embedded.chapters_summary,
        ),
    ] {
        let file_entry = raw["features"][feature][list]
            .as_array()
            .unwrap()
            .iter()
            .find(|candidate| candidate["provider"] == "google" && candidate["model_id"] == model)
            .expect("a trial entry per feature");
        assert_eq!(entry.thinking, file_entry["thinking"].as_str().unwrap());
        assert_eq!(
            u64::from(entry.max_output_tokens),
            file_entry["max_output_tokens"].as_u64().unwrap()
        );
        assert_eq!(
            u64::from(entry.per_call_timeout_seconds),
            file_entry["per_call_timeout_seconds"].as_u64().unwrap()
        );
        assert_eq!(
            entry.response_schema,
            raw["features"][feature]["response_schema"]
        );
    }
    let google = &raw["providers"]["google"];
    assert_eq!(
        embedded.generate_url,
        format!(
            "{}{}",
            google["base_url"].as_str().unwrap(),
            google["generate_path"]
                .as_str()
                .unwrap()
                .replace("{model}", model)
        )
    );
    assert!(embedded
        .generate_url
        .starts_with(&format!("https://{GOOGLE_HOST}/")));
}

type Sections = BTreeMap<String, BTreeMap<String, String>>;

/// The deployed config, when the checkout has one.
const DEPLOYED_CONFIG: &str = "wrangler.toml";
/// The public template: every lane switched off, placeholder identifiers.
const TEMPLATE_CONFIG: &str = "wrangler.example.toml";
/// The template's production route.
const TEMPLATE_HOST: &str = "trial-proxy.example.com";
const TEMPLATE_TEAM_ID: &str = "REPLACE_WITH_APPLE_TEAM_ID";

/// How a config is held, decided by which file it is and never by what it
/// contains: the deployed config to every live value, the public template to
/// its fail-closed posture.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Kind {
    Deployed,
    Template,
}

/// Each config file this checkout carries, deployed first.
fn configs() -> Vec<(&'static str, Kind, Sections)> {
    let configs: Vec<_> = [
        (DEPLOYED_CONFIG, Kind::Deployed),
        (TEMPLATE_CONFIG, Kind::Template),
    ]
    .into_iter()
    .filter_map(|(file, kind)| {
        match std::fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join(file)) {
            Ok(text) => Some((file, kind, parse_sections(&text))),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(error) => panic!("{file}: {error}"),
        }
    })
    .collect();
    assert!(!configs.is_empty(), "no wrangler config to check");
    configs
}

/// The first config present, for the tests that vary one lane's vars.
fn wrangler_sections() -> Sections {
    configs().swap_remove(0).2
}

/// The config of `kind` if the checkout carries it, else the other one.
fn sections_preferring(kind: Kind) -> Sections {
    let mut configs = configs();
    let index = configs
        .iter()
        .position(|(_, candidate, _)| *candidate == kind)
        .unwrap_or(0);
    configs.swap_remove(index).2
}

/// `[section]` → key → value for the flat parts of a wrangler config the
/// worker reads (string values, one per line).
fn parse_sections(text: &str) -> Sections {
    let mut sections = BTreeMap::new();
    let mut current = String::new();
    for line in text.lines().map(str::trim) {
        if line.starts_with('#') || line.is_empty() {
            continue;
        }
        if let Some(name) = line.strip_prefix("[[").and_then(|l| l.strip_suffix("]]")) {
            current = name.to_string();
            continue;
        }
        if let Some(name) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
            current = name.to_string();
            continue;
        }
        if let Some((key, value)) = line.split_once(" = ") {
            let value = value.trim();
            let value = value
                .strip_prefix('"')
                .and_then(|v| v.strip_suffix('"'))
                .or_else(|| value.strip_prefix('\'').and_then(|v| v.strip_suffix('\'')))
                .unwrap_or(value);
            sections
                .entry(current.clone())
                .or_insert_with(BTreeMap::new)
                .insert(key.trim().to_string(), value.to_string());
        }
    }
    sections
}

struct Vars<'a>(&'a BTreeMap<String, String>);

impl VarSource for Vars<'_> {
    fn var(&self, name: &str) -> Option<String> {
        self.0.get(name).cloned()
    }
}

#[test]
fn every_lane_loads_and_agrees_with_the_bundle() {
    for (file, kind, sections) in configs() {
        let failures = failures(kind, &sections);
        assert!(failures.is_empty(), "{file}: {failures:#?}");
    }
}

#[test]
fn a_deployed_config_routed_to_the_placeholder_with_production_off_fails() {
    let mut sections = sections_preferring(Kind::Deployed);
    set(
        &mut sections,
        "env.production.routes",
        "pattern",
        TEMPLATE_HOST,
    );
    set(
        &mut sections,
        "env.production.vars",
        "TRIAL_PROXY_ENABLED",
        "false",
    );
    let failures = failures(Kind::Deployed, &sections).join("\n");
    assert!(failures.contains("production route"), "{failures}");
    assert!(failures.contains("env.production.: enabled"), "{failures}");
}

#[test]
fn a_template_routed_to_the_live_host_with_every_lane_on_fails() {
    let mut sections = sections_preferring(Kind::Template);
    set(
        &mut sections,
        "env.production.routes",
        "pattern",
        trial_endpoint_host().as_str(),
    );
    for vars in ["vars", "env.prod-staging.vars", "env.production.vars"] {
        set(&mut sections, vars, "TRIAL_PROXY_ENABLED", "true");
    }
    let failures = failures(Kind::Template, &sections).join("\n");
    assert!(failures.contains("production route"), "{failures}");
    for prefix in ["", "env.prod-staging.", "env.production."] {
        assert!(
            failures.contains(&format!("{prefix}: TRIAL_PROXY_ENABLED")),
            "{prefix}: {failures}"
        );
    }
}

fn set(sections: &mut Sections, section: &str, key: &str, value: &str) {
    sections
        .get_mut(section)
        .unwrap_or_else(|| panic!("{section}"))
        .insert(key.into(), value.into());
}

/// The host the bundle tells devices to call for the trial.
fn trial_endpoint_host() -> String {
    let (_, text) = highest_manifest();
    let raw: Value = serde_json::from_str(&text).unwrap();
    let endpoint = raw["trial"]["endpoint"].as_str().unwrap();
    endpoint.strip_prefix("https://").unwrap().to_string()
}

/// Every assertion `kind` is held to, as the list of the ones that fail.
fn failures(kind: Kind, sections: &Sections) -> Vec<String> {
    let mut failures = Vec::new();
    let mut expect = |holds: bool, what: String| {
        if !holds {
            failures.push(what);
        }
    };
    let bundle = embedded().unwrap();
    let get = |section: &str, key: &str| {
        sections
            .get(section)
            .and_then(|values| values.get(key))
            .cloned()
            .unwrap_or_default()
    };
    let lanes = [
        (
            "vars",
            "",
            AlertLane::Dev,
            "development",
            5_000_000,
            60,
            1_600_000,
        ),
        (
            "env.prod-staging.vars",
            "env.prod-staging.",
            AlertLane::ProdStaging,
            "production",
            5_000_000,
            60,
            1_600_000,
        ),
        (
            "env.production.vars",
            "env.production.",
            AlertLane::Production,
            "production",
            50_000_000,
            300,
            8_000_000,
        ),
    ];
    for (vars_section, prefix, lane, environment, ceiling, requests, tokens) in lanes {
        let Some(vars) = sections.get(vars_section) else {
            expect(false, format!("{prefix}: no {vars_section}"));
            continue;
        };
        let config = match load(&Vars(vars), bundle) {
            Ok(config) => config,
            Err(error) => {
                expect(false, format!("{prefix}: load {error:?}"));
                continue;
            }
        };
        match kind {
            // Every deployed lane serves, with real identifiers.
            Kind::Deployed => {
                expect(config.enabled, format!("{prefix}: enabled"));
                expect(
                    vars["APPLE_TEAM_ID"] != TEMPLATE_TEAM_ID,
                    format!("{prefix}: APPLE_TEAM_ID is the placeholder"),
                );
                let database = get(&format!("{prefix}d1_databases"), "database_id");
                expect(
                    !database.starts_with("REPLACE_WITH_") && !database.starts_with("TBD"),
                    format!("{prefix}: database_id {database}"),
                );
            }
            // The template serves nothing and names no one's resources.
            Kind::Template => {
                expect(
                    vars["TRIAL_PROXY_ENABLED"] == "false" && !config.enabled,
                    format!("{prefix}: TRIAL_PROXY_ENABLED must be \"false\""),
                );
                expect(
                    vars["APPLE_TEAM_ID"] == TEMPLATE_TEAM_ID,
                    format!("{prefix}: APPLE_TEAM_ID must be the placeholder"),
                );
                let database = get(&format!("{prefix}d1_databases"), "database_id");
                expect(
                    database.starts_with("REPLACE_WITH_") && database.ends_with("D1_DATABASE_ID"),
                    format!("{prefix}: database_id {database}"),
                );
                let name_section = prefix.trim_end_matches('.');
                expect(
                    get(name_section, "name").starts_with("your-trial-proxy-worker"),
                    format!("{prefix}: worker name"),
                );
            }
        }
        expect(config.alert_lane == lane, format!("{prefix}: alert lane"));
        expect(
            config.app_attest_environment == environment,
            format!("{prefix}: App Attest environment"),
        );
        expect(
            config.app_id == format!("{}.{}", vars["APPLE_TEAM_ID"], vars["APPLE_BUNDLE_ID"]),
            format!("{prefix}: app id"),
        );
        expect(
            config.mode_starts_at == bundle.starts_at,
            format!("{prefix}: the flip date is the bundle's"),
        );
        expect(
            config.ledger.lifetime_units == bundle.lifetime_units
                && config.ledger.ceiling_micros == ceiling
                && config.ledger.open_daily_requests == requests
                && config.ledger.open_daily_input_tokens == tokens
                && config.ledger.run_max_windows == 12
                && config.ledger.run_max_input_tokens == 400_000
                && config.ledger.bearer_daily_requests == 40
                && config.ledger.bearer_daily_input_tokens == 2_000_000
                && config.body_max_bytes == 1_572_864,
            format!("{prefix}: ledger limits"),
        );
        expect(
            config
                .ledger
                .prices
                .at(&bundle.model, config.ledger.mode_starts_at_ms)
                .is_some(),
            format!("{prefix}: a price at the flip"),
        );
        expect(
            get(&format!("{prefix}d1_databases"), "binding") == "TRIAL_DB"
                && get(&format!("{prefix}durable_objects.bindings"), "name") == "TRIAL_LEDGER"
                && get(&format!("{prefix}durable_objects.bindings"), "class_name") == "TrialLedger"
                && get(&format!("{prefix}exports.TrialLedger"), "storage") == "sqlite",
            format!("{prefix}: bindings"),
        );
    }
    let route = get("env.production.routes", "pattern");
    match kind {
        // Production serves the host the bundle tells devices to call.
        Kind::Deployed => expect(
            route == trial_endpoint_host(),
            format!("production route {route}"),
        ),
        Kind::Template => {
            expect(route == TEMPLATE_HOST, format!("production route {route}"));
            expect(
                get("env.production.routes", "zone_id").is_empty(),
                "production route zone_id".into(),
            );
        }
    }
    expect(
        get("observability.logs", "invocation_logs") == "false",
        "invocation logs".into(),
    );
    expect(
        get("env.production", "workers_dev") == "false",
        "production workers_dev".into(),
    );
    failures
}

#[test]
fn a_lifetime_count_that_disagrees_with_the_bundle_refuses_everything() {
    let sections = wrangler_sections();
    let mut vars = sections["vars"].clone();
    vars.insert("TRIAL_LIFETIME_UNITS".into(), "6".into());
    let error = load(&Vars(&vars), embedded().unwrap()).unwrap_err();
    assert_eq!(
        (error.field.as_str(), error.reason.as_str()),
        ("TRIAL_LIFETIME_UNITS", "bundle_mismatch")
    );
    vars.insert("TRIAL_LIFETIME_UNITS".into(), "5".into());
    vars.remove("TRIAL_PRICE_TABLE");
    let error = load(&Vars(&vars), embedded().unwrap()).unwrap_err();
    assert_eq!(
        (error.field.as_str(), error.reason.as_str()),
        ("TRIAL_PRICE_TABLE", "missing")
    );
}

#[test]
fn a_missing_or_blank_challenge_source_key_outside_development_is_unavailable() {
    use opencast_trial_proxy_worker::config::{challenge_source_key, ConfigReason};
    use opencast_trial_proxy_worker::route::{error_body, ChallengeSourceFailure, ProxyCode};

    const DEV: &str = "development-fallback-key";
    assert_eq!(
        challenge_source_key(None, "production", DEV),
        Err(ConfigReason::Missing)
    );
    assert_eq!(
        challenge_source_key(Some("  "), "production", DEV),
        Err(ConfigReason::Invalid)
    );
    assert_eq!(
        challenge_source_key(Some(""), "development", DEV),
        Err(ConfigReason::Invalid)
    );
    assert_eq!(
        challenge_source_key(None, "development", DEV).as_deref(),
        Ok(DEV)
    );
    assert_eq!(
        challenge_source_key(Some("a-configured-key"), "production", DEV).as_deref(),
        Ok("a-configured-key")
    );
    // Our configuration is the service being unavailable, never a 500; a
    // request without a client address is the client's.
    let unavailable = ChallengeSourceFailure::KeyUnavailable.proxy_code();
    assert_eq!(unavailable, ProxyCode::TrialUnavailable);
    assert_eq!(unavailable.status(), 503);
    assert_eq!(
        error_body(unavailable, None),
        br#"{"error":"trial_unavailable"}"#
    );
    let missing = ChallengeSourceFailure::MissingSignal.proxy_code();
    assert_eq!(
        (missing.status(), missing.code()),
        (400, "missing_challenge_source")
    );
}

#[test]
fn input_limits_and_reservations_stay_within_the_stored_integer_range() {
    use opencast_trial_proxy_worker::config::{
        price_row_fits, price_table, PriceRow, MAX_STORED_INTEGER, MAX_SUPPORTED_INPUT_TOKENS,
    };

    let table = |limit: u64| {
        format!(
            r#"[{{"model":"gemini-3.8-flash","effective_from":"2026-01-01T00:00:00Z","input_usd_per_million":0.75,"output_usd_per_million":3.75,"max_input_tokens":{limit}}}]"#
        )
    };
    assert!(price_table(&table(MAX_SUPPORTED_INPUT_TOKENS)).is_some());
    assert!(price_table(&table(MAX_SUPPORTED_INPUT_TOKENS + 1)).is_none());
    assert!(price_table(&table(9_007_199_254_740_993)).is_none());
    // A row whose largest reservation (its limit at its input price plus the
    // largest output cap at its output price) would not fit storage.
    let row = |input_price: u64| PriceRow {
        model: "gemini-3.8-flash".into(),
        effective_from_ms: 0,
        input_micros_per_million: input_price,
        output_micros_per_million: 1_000_000,
        max_input_tokens: 1_000_000,
    };
    let output_worst = u64::from(u32::MAX);
    let room = MAX_STORED_INTEGER - output_worst;
    assert!(price_row_fits(&row(room)));
    assert!(!price_row_fits(&row(room + 1)));
}

#[test]
fn the_worst_month_must_fit_the_stored_integer_range() {
    use opencast_trial_proxy_worker::config::{
        cost_micros, ConfigError, ConfigField, ConfigReason, MAX_STORED_INTEGER,
    };

    let sections = wrangler_sections();
    let bundle = embedded().unwrap();
    let max_output = u64::from(
        bundle
            .ad_detection
            .max_output_tokens
            .max(bundle.chapters_summary.max_output_tokens),
    );
    // The largest row the table accepts per reservation: 100M tokens at
    // $1,000 per million in and out.
    let price_table = r#"[{"model":"gemini-3.8-flash","effective_from":"2026-01-01T00:00:00Z","input_usd_per_million":1000,"output_usd_per_million":1000,"max_input_tokens":100000000}]"#;
    let window = cost_micros(100_000_000, 1_000_000_000) + cost_micros(max_output, 1_000_000_000);
    // A month and its spill month, 31 days at the larger daily request cap.
    let largest_daily = (MAX_STORED_INTEGER - 1) / (2 * 31 * window);
    let with = |daily: u64| {
        let mut vars = sections["vars"].clone();
        vars.insert("TRIAL_PRICE_TABLE".into(), price_table.into());
        vars.insert("TRIAL_OPEN_DAILY_REQUESTS".into(), daily.to_string());
        vars.insert("TRIAL_BEARER_DAILY_REQUESTS".into(), "1".into());
        load(&Vars(&vars), bundle).map(|_| ())
    };
    assert_eq!(with(largest_daily), Ok(()));
    assert_eq!(
        with(largest_daily + 1),
        Err(ConfigError {
            field: ConfigField::TrialPriceTable,
            reason: ConfigReason::MonthOutOfRange,
        })
    );
    // The larger of the two caps counts: the ops lane's cap alone crosses it.
    let mut vars = sections["vars"].clone();
    vars.insert("TRIAL_PRICE_TABLE".into(), price_table.into());
    vars.insert("TRIAL_OPEN_DAILY_REQUESTS".into(), "1".into());
    vars.insert(
        "TRIAL_BEARER_DAILY_REQUESTS".into(),
        (largest_daily + 1).to_string(),
    );
    assert!(load(&Vars(&vars), bundle).is_err());
    // Every lane's real configuration is far inside it.
    for section in ["vars", "env.prod-staging.vars", "env.production.vars"] {
        assert!(load(&Vars(&sections[section]), bundle).is_ok(), "{section}");
    }
}
