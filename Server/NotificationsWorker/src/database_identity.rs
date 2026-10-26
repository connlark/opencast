//! Pure storage identity, shared by the wasm database tree and host tests.
//!
//! A version opts into the bind-time gate by pinning `STORAGE_IDENTITY` =
//! `v1;<environment>;postgres;pg:<datname>[:<system identifier>]`. The schema
//! identity is compiled in from the shipped migrations. Rows are canonicalised
//! exactly as the cutover tool does: `null`, a decimal integer, or
//! `"t:<hex of UTF-8>"`.
use serde_json::Value;
use sha2::{Digest, Sha256};

/// The 32 application tables, in byte order.
pub(crate) const APPLICATION_TABLES: [&str; 32] = [
    "app_attest_challenge_source_buckets",
    "app_attest_challenges",
    "app_attest_keys",
    "devices",
    "feed_admission_attempts",
    "feed_subscriptions",
    "n_burst",
    "n_circuit",
    "n_control",
    "n_deleted_install",
    "n_delivery",
    "n_delivery_history",
    "n_delivery_member",
    "n_episode_release",
    "n_event",
    "n_feed",
    "n_feed_catalog",
    "n_group_member",
    "n_install",
    "n_interest",
    "n_job_interest",
    "n_legacy_bridge",
    "n_observation",
    "n_outbox",
    "n_poll_dispatch",
    "n_poll_origin",
    "n_poll_stat",
    "n_requester_ticket",
    "n_snapshot",
    "n_snapshot_ref",
    "push_send_attempts",
    "secure_hello_attempts",
];

/// SHA-256 of the catalog text (columns and types, primary keys, trigger
/// names and enabled states of the 32 tables) that a fresh install of the
/// shipped PostgreSQL migrations produces. Derived by applying them to an
/// empty PostgreSQL 18 database; `POSTGRES_MIGRATIONS` pins those inputs.
pub(crate) const POSTGRES_SCHEMA: &str =
    "e75c21086694d9ee8d7159797836732852a78a8c1164ca314184dcf0eec26a52";
/// SHA-256 of the shipped PostgreSQL migration files, concatenated in order.
#[cfg(test)]
pub(crate) const POSTGRES_MIGRATIONS: &str =
    "29538044238a354c3cd76082c02989ef05178a9c7c02ab219a7b0345b6795b4b";

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Database {
    Postgres {
        name: String,
        system: Option<String>,
    },
}

impl Database {
    pub(crate) fn text(&self) -> String {
        match self {
            Self::Postgres { name, system: None } => format!("pg:{name}"),
            Self::Postgres {
                name,
                system: Some(system),
            } => format!("pg:{name}:{system}"),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Pin {
    pub(crate) environment: String,
    pub(crate) database: Database,
}

impl Pin {
    /// PostgreSQL reads the system identifier only when the pin names one.
    pub(crate) fn reads_system(&self) -> bool {
        matches!(
            self.database,
            Database::Postgres {
                system: Some(_),
                ..
            }
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Reason {
    Pin,
    Environment,
    Schema,
    Database,
}

impl Reason {
    pub(crate) fn code(self) -> &'static str {
        match self {
            Self::Pin => "pin",
            Self::Environment => "environment",
            Self::Schema => "schema",
            Self::Database => "database",
        }
    }
}

/// The one storage backend, as the readback and log report it.
pub(crate) fn backend_code() -> &'static str {
    "postgres"
}

fn label(value: &str) -> bool {
    !value.is_empty()
        && value
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-' || b == b'_')
}

#[cfg(test)]
fn lower_hex(value: &str, len: usize) -> bool {
    value.len() == len
        && value
            .bytes()
            .all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// Parse a pin. Any other shape, another backend included, is malformed.
pub(crate) fn parse(pin: &str) -> Option<Pin> {
    let mut parts = pin.split(';');
    let (Some("v1"), Some(environment), Some(backend), Some(database), None) = (
        parts.next(),
        parts.next(),
        parts.next(),
        parts.next(),
        parts.next(),
    ) else {
        return None;
    };
    if !label(environment) || backend != "postgres" {
        return None;
    }
    let rest = database.strip_prefix("pg:")?;
    let (name, system) = match rest.split_once(':') {
        Some((name, system)) => (name, Some(system)),
        None => (rest, None),
    };
    let name_ok = !name.is_empty()
        && name
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_');
    let system_ok = system.is_none_or(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()));
    if !name_ok || !system_ok {
        return None;
    }
    Some(Pin {
        environment: environment.into(),
        database: Database::Postgres {
            name: name.into(),
            system: system.map(Into::into),
        },
    })
}

/// The check that needs no database read: the environment.
pub(crate) fn admit(pin: &Pin, environment: Option<&str>) -> Result<(), Reason> {
    if environment != Some(pin.environment.as_str()) {
        return Err(Reason::Environment);
    }
    Ok(())
}

/// The PostgreSQL identity read. One statement, no parameters; the cutover
/// tool's schema (columns, types, primary keys) and trigger texts restricted
/// to the application tables by name. Its digests are pinned by a host test.
pub(crate) fn postgres_identity_sql(system: bool) -> String {
    let names = APPLICATION_TABLES
        .iter()
        .map(|name| format!("'{name}'"))
        .collect::<Vec<_>>()
        .join(",");
    let tables = format!("c.relname::text = ANY (ARRAY[{names}]::text[])");
    let system = if system {
        "(SELECT system_identifier::text FROM pg_control_system())"
    } else {
        "NULL::text"
    };
    format!(
        "SELECT current_database()::text AS database, {system} AS system, encode(sha256(convert_to(\
         COALESCE((SELECT string_agg(x.line, '/' ORDER BY x.relname COLLATE \"C\") FROM (SELECT c.relname, \
         c.relname||':'||(SELECT string_agg(a.attname||'='||format_type(a.atttypid, a.atttypmod), ',' ORDER BY a.attnum) \
         FROM pg_attribute a WHERE a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped)||';pk='||\
         COALESCE((SELECT string_agg(a.attname, ',' ORDER BY k.ord) FROM pg_index i CROSS JOIN LATERAL \
         unnest(i.indkey::int2[]) WITH ORDINALITY k(attnum, ord) JOIN pg_attribute a ON a.attrelid=i.indrelid \
         AND a.attnum=k.attnum WHERE i.indrelid=c.oid AND i.indisprimary), '') AS line FROM pg_class c \
         JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='opencast' AND c.relkind IN ('r','p') \
         AND {tables}) x), '')||'#'||COALESCE((SELECT string_agg(c.relname||'.'||t.tgname||'='||t.tgenabled::text, \
         ',' ORDER BY c.relname COLLATE \"C\", t.tgname COLLATE \"C\") FROM pg_trigger t JOIN pg_class c \
         ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='opencast' \
         AND NOT t.tgisinternal AND {tables}), ''), 'UTF8')), 'hex') AS schema"
    )
}

/// What the bound database reports about itself.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Live {
    pub(crate) schema: String,
    pub(crate) database: Database,
}

/// The expected schema identity, as logged and compared.
pub(crate) fn expected_schema() -> &'static str {
    POSTGRES_SCHEMA
}

/// Order: schema, then database.
pub(crate) fn judge(pin: &Pin, live: &Live) -> Result<(), Reason> {
    if live.schema != expected_schema() {
        return Err(Reason::Schema);
    }
    if live.database != pin.database {
        return Err(Reason::Database);
    }
    Ok(())
}

/// One canonical value token. Decoded storage rows carry only null, integers
/// (booleans already mapped to integer flags) and text.
pub(crate) fn token(value: &Value) -> String {
    match value {
        Value::Null => "null".into(),
        Value::Bool(flag) => i64::from(*flag).to_string(),
        Value::Number(number) => number
            .as_i64()
            .map(|n| n.to_string())
            .unwrap_or_else(|| format!("\"r:{number}\"")),
        Value::String(text) => format!("\"t:{}\"", hex::encode(text.as_bytes())),
        other => format!("\"j:{}\"", hex::encode(other.to_string().as_bytes())),
    }
}

pub(crate) fn line<'a>(values: impl Iterator<Item = &'a Value>) -> String {
    let tokens: Vec<String> = values.map(token).collect();
    format!("[{}]", tokens.join(","))
}

fn row_digest(line: &str) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(line.as_bytes());
    hasher.update(b"\n");
    hasher.finalize().into()
}

/// The cutover tool's table digest: SHA-256 over the row digests in order.
#[cfg(test)]
pub(crate) fn table_digest<'a>(lines: impl Iterator<Item = &'a String>) -> String {
    let mut hasher = Sha256::new();
    for line in lines {
        hasher.update(row_digest(line));
    }
    hex::encode(hasher.finalize())
}

/// Digest of the rows an Unknown readback observed. Each row's line starts
/// with its reply index, then its values in column-name order; readbacks
/// share no key, so the row digests are aggregated in ascending order.
pub(crate) fn witness<'a>(replies: impl Iterator<Item = &'a [Value]>) -> (String, usize) {
    let mut digests = Vec::new();
    for (index, rows) in replies.enumerate() {
        for row in rows {
            let index = Value::from(index as i64);
            let values: Vec<&Value> = match row {
                Value::Object(columns) => columns.values().collect(),
                other => vec![other],
            };
            digests.push(row_digest(&line(std::iter::once(&index).chain(values))));
        }
    }
    digests.sort_unstable();
    let mut hasher = Sha256::new();
    for digest in &digests {
        hasher.update(digest);
    }
    (hex::encode(hasher.finalize()), digests.len())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::path::Path;

    const SYSTEM: &str = "7412345678901234567";

    #[test]
    fn pins_parse_only_in_the_closed_shapes() {
        let pg = parse(&format!("v1;production;postgres;pg:opencast:{SYSTEM}")).unwrap();
        assert_eq!(
            pg,
            Pin {
                environment: "production".into(),
                database: Database::Postgres {
                    name: "opencast".into(),
                    system: Some(SYSTEM.into()),
                },
            }
        );
        assert!(pg.reads_system());
        assert_eq!(pg.database.text(), format!("pg:opencast:{SYSTEM}"));
        let fallback = parse("v1;production;postgres;pg:opencast").unwrap();
        assert!(!fallback.reads_system());
        let bad = [
            String::new(),
            // A D1 pin is malformed: PostgreSQL is the only backend.
            format!("v1;pg-rehearsal;d1;ledger:{}", "a".repeat(64)),
            format!("v2;production;d1;ledger:{}", "a".repeat(64)),
            format!("v1;production;d1;ledger:{}", "A".repeat(64)),
            format!("v1;production;d1;ledger:{}", "a".repeat(63)),
            format!("v1;production;postgres;ledger:{}", "a".repeat(64)),
            "v1;production;d1;pg:opencast".into(),
            "v1;;postgres;pg:opencast".into(),
            "v1;Production;postgres;pg:opencast".into(),
            "v1;production;postgres;pg:".into(),
            "v1;production;postgres;pg:opencast:12a".into(),
            "v1;production;postgres;pg:opencast:".into(),
            "v1;production;postgres;pg:open-cast".into(),
            "v1;production;postgres;pg:REPLACE_WITH_DATABASE_NAME:REPLACE_WITH_SYSTEM_IDENTIFIER"
                .into(),
            "v1;production;mysql;pg:opencast".into(),
            "v1;production;postgres;pg:opencast;extra".into(),
            " v1;production;postgres;pg:opencast".into(),
        ];
        for pin in bad {
            assert_eq!(parse(&pin), None, "{pin}");
        }
    }

    #[test]
    fn the_environment_is_checked_before_any_read() {
        let pin = parse(&format!("v1;pg-rehearsal;postgres;pg:opencast:{SYSTEM}")).unwrap();
        assert_eq!(admit(&pin, Some("pg-rehearsal")), Ok(()));
        assert_eq!(admit(&pin, Some("prod-staging")), Err(Reason::Environment));
        assert_eq!(admit(&pin, None), Err(Reason::Environment));
    }

    #[test]
    fn the_postgres_verdict_checks_schema_then_database() {
        let pin = parse(&format!("v1;production;postgres;pg:opencast:{SYSTEM}")).unwrap();
        let live = Live {
            schema: POSTGRES_SCHEMA.into(),
            database: Database::Postgres {
                name: "opencast".into(),
                system: Some(SYSTEM.into()),
            },
        };
        assert_eq!(judge(&pin, &live), Ok(()));
        let other_schema = Live {
            schema: "0".repeat(64),
            ..live.clone()
        };
        assert_eq!(judge(&pin, &other_schema), Err(Reason::Schema));
        let other_database = Live {
            database: Database::Postgres {
                name: "opencast_staging".into(),
                system: Some(SYSTEM.into()),
            },
            ..live.clone()
        };
        assert_eq!(judge(&pin, &other_database), Err(Reason::Database));
        let other_cluster = Live {
            database: Database::Postgres {
                name: "opencast".into(),
                system: Some("1".into()),
            },
            ..live.clone()
        };
        assert_eq!(judge(&pin, &other_cluster), Err(Reason::Database));
        // The schema is judged first.
        let both = Live {
            schema: "0".repeat(64),
            ..other_database.clone()
        };
        assert_eq!(judge(&pin, &both), Err(Reason::Schema));
        // A pin without a system identifier reads none and matches on the name.
        let unpinned = parse("v1;production;postgres;pg:opencast").unwrap();
        let named = Live {
            database: Database::Postgres {
                name: "opencast".into(),
                system: None,
            },
            ..live.clone()
        };
        assert_eq!(judge(&unpinned, &named), Ok(()));
        assert_eq!(judge(&unpinned, &live), Err(Reason::Database));
    }

    #[test]
    fn tokens_and_lines_match_the_cutover_tool() {
        // The tool's golden tokens: exact UTF-8 bytes, lowercase hex.
        assert_eq!(token(&json!("é😀\u{0}")), "\"t:c3a9f09f988000\"");
        assert_eq!(token(&json!("")), "\"t:\"");
        assert_eq!(token(&json!(-5)), "-5");
        assert_eq!(token(&Value::Null), "null");
        // A nested JSON value: compact JSON with sorted keys, hex-encoded.
        assert_eq!(
            token(&json!({"b": 1, "a": "x"})),
            format!("\"j:{}\"", hex::encode(r#"{"a":"x","b":1}"#))
        );
        assert_eq!(
            line([json!(1), Value::Null, json!("a")].iter()),
            "[1,null,\"t:61\"]"
        );
        // sha256(b"") for an empty table, as the tool's digest.
        assert_eq!(
            table_digest(std::iter::empty()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn the_witness_is_order_independent_and_counts_rows() {
        let a = vec![json!({"b": 2, "a": "x"}), json!({"a": null, "b": 1})];
        let b = vec![json!({"relation": "n_feed", "row_json": "{}"})];
        let (one, rows) = witness([a.as_slice(), b.as_slice()].into_iter());
        let reversed: Vec<Value> = a.iter().rev().cloned().collect();
        let (two, _) = witness([reversed.as_slice(), b.as_slice()].into_iter());
        assert_eq!(rows, 3);
        assert_eq!(one, two);
        // The reply index is part of each line.
        let (swapped, _) = witness([b.as_slice(), a.as_slice()].into_iter());
        assert_ne!(one, swapped);
        let (empty, none) = witness(std::iter::empty());
        assert_eq!(none, 0);
        assert_eq!(
            empty,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn reasons_and_backends_have_fixed_codes() {
        let reasons = [
            Reason::Pin,
            Reason::Environment,
            Reason::Schema,
            Reason::Database,
        ];
        let codes: Vec<_> = reasons.iter().map(|reason| reason.code()).collect();
        assert_eq!(codes, ["pin", "environment", "schema", "database"]);
        assert_eq!(backend_code(), "postgres");
        assert_eq!(expected_schema(), POSTGRES_SCHEMA);
    }

    #[test]
    fn the_postgres_identity_read_is_one_pinned_statement() {
        // The rehearsal harness builds the same text and checks these digests.
        let digest = |text: String| hex::encode(Sha256::digest(text.as_bytes()));
        assert_eq!(
            digest(postgres_identity_sql(true)),
            "e733a8988ea6dc5ab4f9658745864cd54ead5a7ba0fc090795b25ad0648e4b52"
        );
        assert_eq!(
            digest(postgres_identity_sql(false)),
            "0010741326e25e4fa02ea5701bd3ee32ef2b6dadbf1b21d8d07211e0f2641b64"
        );
        for system in [true, false] {
            let text = postgres_identity_sql(system);
            assert!(text.starts_with("SELECT current_database()::text AS database, "));
            // One statement and no bind parameters (`;pk=` is a string literal).
            assert_eq!(text.matches(';').count(), 1);
            assert!(text.contains("';pk='") && !text.contains('$'));
            assert!(!text.to_uppercase().contains(" FOR UPDATE"));
            assert_eq!(text.contains("pg_control_system()"), system);
            for table in APPLICATION_TABLES {
                assert_eq!(text.matches(&format!("'{table}'")).count(), 2, "{table}");
            }
        }
    }

    #[test]
    fn the_compiled_schema_constants_pin_the_shipped_migrations() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR"));
        let mut postgres = Sha256::new();
        for name in [
            "0001_slice_a.sql",
            "0002_slice_b.sql",
            "0003_delivery_member.sql",
            "0004_identity_delivery_support.sql",
            "0005_retire_five_minute_polling.sql",
        ] {
            postgres.update(std::fs::read(root.join("postgres/migrations").join(name)).unwrap());
        }
        let shipped: Vec<String> = std::fs::read_dir(root.join("postgres/migrations"))
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect();
        // A new migration re-pins POSTGRES_MIGRATIONS, and POSTGRES_SCHEMA only
        // when it changes the catalog (0005 deletes a seed row: data only).
        assert_eq!(
            shipped.len(),
            5,
            "a new PostgreSQL migration re-pins POSTGRES_MIGRATIONS (and POSTGRES_SCHEMA when it changes the catalog)"
        );
        // Editing a migration changes this digest: regenerate POSTGRES_SCHEMA
        // from a fresh install of the edited files, then update both constants.
        assert_eq!(hex::encode(postgres.finalize()), POSTGRES_MIGRATIONS);
        assert!(lower_hex(POSTGRES_SCHEMA, 64));
        let mut tables = APPLICATION_TABLES.to_vec();
        tables.sort_unstable();
        assert_eq!(tables, APPLICATION_TABLES);
    }
}
