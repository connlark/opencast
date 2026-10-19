//! Typed identity statements; each write takes the shared mutation gate first.
use super::*;
use crate::database::slice_c::{Operation, Response, SubscriptionWrite};
use opencast_app_attest_core::{app_attest, challenge_limits};
use serde_json::{json, Map, Value};

// Subscription deletion updates an enabled interest, which performs two feed
// updates and suppresses deliveries at the new generation. D1 meta.changes
// includes those writes. Count their original predicates before deleting;
// RETURNING ties each contribution to an actual deleted subscription.
const GC_SUBSCRIPTIONS: &str = r#"WITH selected AS MATERIALIZED (
 SELECT s.install_id,s.feed_url,COALESCE((SELECT SUM(3+(SELECT COUNT(*) FROM n_delivery d
   WHERE d.install_id=i.install_id AND d.interest_key=i.feed_id
   AND d.interest_generation<>i.generation+1 AND d.state IN('pending','leased','uncertain','poisoned')))
  FROM n_interest i JOIN n_feed f ON f.feed_id=i.feed_id
  WHERE i.install_id=s.install_id AND f.canonical_url=s.feed_url AND i.enabled=1),0)::bigint AS effects
 FROM feed_subscriptions s WHERE s.deleted_at IS NOT NULL AND s.deleted_at<$1
), deleted AS (
 DELETE FROM feed_subscriptions s USING selected x
 WHERE s.install_id=x.install_id AND s.feed_url=x.feed_url RETURNING x.effects
) SELECT COALESCE(SUM(1+effects),0)::bigint AS count FROM deleted"#;

struct Plan {
    statements: Vec<Statement>,
    // The source bucket's first() is outside its run(), on a fresh snapshot.
    after: Option<Statement>,
}
pub(in crate::database) async fn execute(
    env: &worker::Env,
    operation: &Operation,
    cancel: Cancellation,
    deadline: u64,
) -> Result<Response> {
    crate::database::slice_c::validate(operation)?;
    let started = now();
    // Native list readers return their empty map without opening a database.
    if matches!(operation, Operation::FeedSummaries { urls } if urls.is_empty())
        || matches!(operation, Operation::CountHostAdmissions { hosts, .. } if hosts.is_empty())
    {
        return Ok(Response {
            value: json!({}),
            metrics: Metrics::default(),
            physical_counts: Some(vec![]),
        });
    }
    let plan = describe(operation);
    for statement in plan.statements.iter().chain(plan.after.iter()) {
        statement.validate()?;
    }
    let read = operation.is_read();
    let classify = |mut error: Failure| {
        if read {
            error.outcome = Outcome::NotApplicable;
        }
        error
    };
    if plan.statements.is_empty() {
        return Ok(Response {
            value: Value::Null,
            metrics: Metrics::default(),
            physical_counts: Some(vec![]),
        });
    }
    if deadline <= started {
        return Err(classify(Failure::new(Kind::Deadline, Phase::Connect)));
    }
    let connect = Database::connect(env, cancel, started);
    let expiry = delay(deadline - started);
    pin_mut!(connect, expiry);
    let mut db = match select(connect, expiry).await {
        Either::Left((connected, _)) => connected.map_err(classify)?,
        Either::Right(((), _)) => {
            return Err(classify(Failure::new(Kind::Deadline, Phase::Connect)))
        }
    };
    db.cap_deadline(deadline);
    let mut metrics = Metrics::default();
    let result = if read {
        db.read_statement(&plan.statements[0])
            .await
            .map(|r| vec![r])
    } else {
        let gate = Statement {
            sql: GATE.into(),
            parameters: vec![],
            count: CountRule::Exactly(1),
        };
        db.write_transaction(&gate, &plan.statements)
            .await
            .and_then(|reply| {
                metrics.gate_wait_us = Some(
                    reply
                        .gate
                        .rows
                        .first()
                        .ok_or_else(|| decode_failure(false))?
                        .try_get("gate_wait_us")
                        .map_err(|_| decode_failure(false))?,
                );
                Ok(reply.statements)
            })
    };
    let result = match (result, plan.after.as_ref()) {
        (Ok(mut replies), Some(statement)) => db
            .read_statement(statement)
            .await
            .map(|reply| {
                replies.push(reply);
                replies
            })
            .map_err(|mut error| {
                error.outcome = Outcome::Unknown;
                error
            }),
        (result, None) => result,
        (Err(error), Some(_)) => Err(error),
    };
    let (spans, _cleanup) = db.finish().await;
    metrics.handler_ms = now().saturating_sub(started);
    metrics.transaction_ms = spans
        .iter()
        .find(|s| s.boundary == "transaction")
        .map_or(0, |s| s.elapsed_ms);
    metrics.gate_reply_ms = spans
        .iter()
        .find(|s| s.boundary == "gate")
        .map(|s| s.elapsed_ms);
    let replies = result?;
    let statements: Vec<_> = plan.statements.iter().chain(plan.after.iter()).collect();
    if replies.len() != statements.len() {
        return Err(decode_failure(read));
    }
    let mut rows = vec![];
    let mut counts = vec![];
    for (reply, statement) in replies.into_iter().zip(statements) {
        if !statement.count.accepts(reply.affected) {
            return Err(decode_failure(read));
        }
        counts.push(reply.affected);
        rows.push(
            reply
                .rows
                .into_iter()
                .map(|row| decode_identity(row, read))
                .collect::<Result<Vec<_>>>()?,
        );
    }
    let value = domain_value(operation, &rows, &counts)?;
    Ok(Response {
        value,
        metrics,
        physical_counts: Some(counts),
    })
}
fn statement(sql: &str, parameters: Vec<Parameter>, count: CountRule) -> Statement {
    Statement {
        sql: sql.into(),
        parameters,
        count,
    }
}
fn nullable_text(value: &Option<String>) -> Parameter {
    Parameter::Text(value.clone())
}
fn texts(values: &[String]) -> Parameter {
    Parameter::TextArray(Some(values.iter().cloned().map(Some).collect()))
}
fn describe(operation: &Operation) -> Plan {
    use Operation::*;
    let one = CountRule::AtMost(1);
    let any = CountRule::Any;
    let mut after = None;
    let statements=match operation {
        PruneChallengeSourceBuckets {cutoff}=>vec![statement("DELETE FROM app_attest_challenge_source_buckets WHERE updated_at<$1",vec![integer(*cutoff)],any)],
        PruneChallenges {cutoff}=>vec![statement("DELETE FROM app_attest_challenges WHERE created_at<$1",vec![integer(*cutoff)],any)],
        PrunePushAttempts {cutoff}=>vec![statement("DELETE FROM push_send_attempts WHERE created_at<$1",vec![integer(*cutoff)],any)],
        GcDeletedSubscriptions {cutoff}=>vec![statement(GC_SUBSCRIPTIONS,vec![integer(*cutoff)],CountRule::Exactly(1))],
        PruneSecureAttempts {cutoff}=>vec![statement("DELETE FROM secure_hello_attempts WHERE created_at<$1",vec![integer(*cutoff)],any)],
        PruneAdmissionAttempts {cutoff}=>vec![statement("DELETE FROM feed_admission_attempts WHERE created_at<$1",vec![integer(*cutoff)],any)],
        IssueChallenge {id,challenge,purpose,install,created,expires,window_start}=>vec![statement(
            "INSERT INTO app_attest_challenges(challenge_id,challenge_hash,purpose,install_id,created_at,expires_at) SELECT $1,$2,$3,$4,$5,$6 WHERE (SELECT COUNT(*) FROM app_attest_challenges WHERE install_id=$4 AND created_at>=$7)<$8 AND (SELECT COUNT(*) FROM app_attest_challenges WHERE created_at>=$7)<$9",
            vec![text(id),text(app_attest::challenge_hash(challenge)),text(purpose),text(install),integer(*created),integer(*expires),integer(*window_start),integer(challenge_limits::MAX_CHALLENGES_PER_INSTALL_PER_HOUR),integer(challenge_limits::MAX_GLOBAL_CHALLENGES_PER_HOUR)],one)],
        ReadChallenge {id}=>vec![statement("SELECT challenge_hash,purpose,install_id,expires_at,consumed_at FROM app_attest_challenges WHERE challenge_id=$1 LIMIT 1",vec![text(id)],one)],
        IncrementSource {source,window_start,now}=>{
            after=Some(statement("SELECT request_count AS count FROM app_attest_challenge_source_buckets WHERE source_token=$1 AND window_start=$2 LIMIT 1",vec![text(source),integer(*window_start)],one));
            vec![statement("INSERT INTO app_attest_challenge_source_buckets(source_token,window_start,request_count,updated_at) VALUES($1,$2,1,$3) ON CONFLICT(source_token,window_start) DO UPDATE SET request_count=app_attest_challenge_source_buckets.request_count+1,updated_at=excluded.updated_at",vec![text(source),integer(*window_start),integer(*now)],one)]
        },
        DeleteIdentity {install}=>vec![
            statement("DELETE FROM app_attest_challenges WHERE install_id=$1",vec![text(install)],any),
            statement("DELETE FROM app_attest_keys WHERE install_id=$1",vec![text(install)],any)],
        ConsumeChallenge {id,now}=>vec![statement("UPDATE app_attest_challenges SET consumed_at=$1 WHERE challenge_id=$2 AND consumed_at IS NULL",vec![integer(*now),text(id)],one)],
        ReadKey {install,key}=>vec![statement("SELECT public_key,sign_counter,app_id,environment FROM app_attest_keys WHERE install_id=$1 AND key_id=$2 LIMIT 1",vec![text(install),text(key)],one)],
        CountKeys {install,since}=>vec![statement("SELECT COUNT(*) AS count FROM app_attest_keys WHERE install_id=$1 AND created_at>=$2",vec![text(install),integer(*since)],CountRule::Exactly(1))],
        AdvanceCounter {install,key,previous,next,now}=>vec![statement("UPDATE app_attest_keys SET sign_counter=$1,last_used_at=$2 WHERE install_id=$3 AND key_id=$4 AND sign_counter=$5",vec![integer(*next),integer(*now),text(install),text(key),integer(*previous)],one)],
        RegisterKey {install,key,public_key,app_id,environment,now,challenge}=>vec![statement("INSERT INTO app_attest_keys(install_id,key_id,public_key,sign_counter,app_id,environment,created_at,last_used_at) SELECT $1,$2,$3,0,$4,$5,$6,$6 WHERE EXISTS(SELECT 1 FROM app_attest_challenges WHERE challenge_id=$7 AND install_id=$1 AND purpose='register' AND consumed_at=$6 AND expires_at>=$6) ON CONFLICT(install_id,key_id) DO UPDATE SET public_key=excluded.public_key,app_id=excluded.app_id,environment=excluded.environment,last_used_at=excluded.last_used_at",vec![text(install),text(key),Parameter::Bytes(Some(public_key.clone())),text(app_id),text(environment),integer(*now),text(challenge)],one)],
        RegisterDevice {device:d}=>vec![
            statement("INSERT INTO devices(install_id,key_id,device_token,device_token_hash,apns_environment,bundle_id,notifications_enabled,created_at,last_seen_at,job_capable) SELECT $1,$2,$3,$4,$5,$6,$7,$8,$9,$10 WHERE EXISTS(SELECT 1 FROM app_attest_keys WHERE install_id=$1 AND key_id=$2) ON CONFLICT(install_id,device_token_hash) DO UPDATE SET key_id=excluded.key_id,device_token=excluded.device_token,apns_environment=excluded.apns_environment,bundle_id=excluded.bundle_id,notifications_enabled=excluded.notifications_enabled,job_capable=excluded.job_capable,last_seen_at=excluded.last_seen_at",vec![text(&d.install),text(&d.key),text(&d.token),text(&d.token_hash),text(&d.environment),text(&d.bundle),integer(i64::from(d.enabled)),integer(d.now),integer(d.now),integer(i64::from(d.job_capable))],one),
            statement("DELETE FROM devices WHERE install_id=$1 AND apns_environment=$2 AND bundle_id=$3 AND device_token_hash<>$4 AND EXISTS(SELECT 1 FROM app_attest_keys WHERE install_id=$1 AND key_id=$5)",vec![text(&d.install),text(&d.environment),text(&d.bundle),text(&d.token_hash),text(&d.key)],any)],
        DisableDevice {install,token_hash,now}=>vec![statement("UPDATE devices SET device_token=$1,notifications_enabled=$2,last_seen_at=$3 WHERE install_id=$4 AND device_token_hash=$5",vec![text(""),integer(0),integer(*now),text(install),text(token_hash)],one)],
        DeviceExists {install,token_hash}=>vec![statement("SELECT COUNT(*) AS count FROM devices WHERE install_id=$1 AND device_token_hash=$2",vec![text(install),text(token_hash)],CountRule::Exactly(1))],
        CountEnabledDevices {install,environment,bundle}=>vec![statement("SELECT COUNT(*) AS count FROM devices WHERE install_id=$1 AND apns_environment=$2 AND bundle_id=$3 AND notifications_enabled=1",vec![text(install),text(environment),text(bundle)],CountRule::Exactly(1))],
        LatestDevice {install,environment}=>vec![statement("SELECT device_token,device_token_hash FROM devices WHERE install_id=$1 AND apns_environment=$2 AND notifications_enabled=1 ORDER BY last_seen_at DESC LIMIT 1",vec![text(install),text(environment)],one)],
        RegistrationReady {install,environment,bundle}=>vec![statement("SELECT COUNT(*) AS count FROM n_install i JOIN devices d ON d.install_id=i.install_id AND d.device_token_hash=i.token_hash WHERE i.install_id=$1 AND i.enabled=1 AND d.notifications_enabled=1 AND d.device_token<>'' AND d.apns_environment=$2 AND d.bundle_id=$3",vec![text(install),text(environment),text(bundle)],CountRule::Exactly(1))],
        SecureAttempt {id,install,key,accepted,error,now}=>vec![statement("INSERT INTO secure_hello_attempts(attempt_id,install_id,key_id,accepted,error_code,created_at) VALUES($1,$2,$3,$4,$5,$6)",vec![text(id),nullable_text(install),nullable_text(key),integer(i64::from(*accepted)),nullable_text(error),integer(*now)],one)],
        PushAttempt {id,install,token_hash,environment,status,apns_id,error,now}=>vec![statement("INSERT INTO push_send_attempts(attempt_id,install_id,device_token_hash,apns_environment,apns_status,apns_id,apns_error,created_at) SELECT $1,$2,$3,$4,$5,$6,$7,$8 WHERE $2 IS NULL OR EXISTS(SELECT 1 FROM n_install WHERE install_id=$2)",vec![text(id),nullable_text(install),nullable_text(token_hash),text(environment),Parameter::Integer(status.map(i64::from)),nullable_text(apns_id),nullable_text(error),integer(*now)],one)],
        FeedSummaries {urls}=>vec![statement("SELECT c.feed_url,c.title,CASE WHEN n.feed_id IS NOT NULL THEN n.poll_failures ELSE COALESCE((c.admission_health_json::json->>'consecutive_failures')::bigint,0) END AS consecutive_failures,CASE WHEN n.feed_id IS NULL THEN (c.admission_health_json::json->>'last_http_status')::bigint END AS last_http_status,CASE WHEN n.feed_id IS NOT NULL THEN CASE WHEN n.poll_failures>0 THEN 'poll_failed' END ELSE c.admission_health_json::json->>'last_error' END AS last_error,CASE WHEN n.feed_id IS NOT NULL THEN n.last_success_at ELSE (c.admission_health_json::json->>'last_polled_at')::bigint END AS last_polled_at FROM n_feed_catalog c LEFT JOIN n_feed n ON n.canonical_url=c.feed_url WHERE c.feed_url=ANY($1)",vec![texts(urls)],any)],
        CountAdmissions {install,since}=>vec![statement("SELECT COUNT(*) AS count FROM feed_admission_attempts WHERE install_id=$1 AND accepted=1 AND created_at>=$2",vec![text(install),integer(*since)],CountRule::Exactly(1))],
        CountHostAdmissions {hosts,since}=>vec![statement("SELECT host,COUNT(*) AS count FROM feed_admission_attempts WHERE accepted=1 AND created_at>=$1 AND host=ANY($2) GROUP BY host",vec![integer(*since),texts(hosts)],any)],
        CountGlobalAdmissions {since}=>vec![statement("SELECT COUNT(*) AS count FROM feed_admission_attempts WHERE accepted=1 AND created_at>=$1",vec![integer(*since)],CountRule::Exactly(1))],
        ReadSubscriptions {install}=>vec![statement("SELECT feed_url FROM feed_subscriptions WHERE install_id=$1 AND deleted_at IS NULL ORDER BY feed_url COLLATE \"C\"",vec![text(install)],any)],
        SyncSubscriptions {writes}=>subscriptions(writes),
        EraseInstall {install,fence,now}=>{
            let mut writes=vec![statement("INSERT INTO n_deleted_install(fence,expires_at) VALUES($1,$2) ON CONFLICT(fence) DO NOTHING",vec![text(fence),integer(*now+604800)],one),
                statement("UPDATE n_interest SET changed_at=$2 WHERE install_id=$1",vec![text(install),integer(*now)],any)];
            for sql in [
                "DELETE FROM n_delivery_member WHERE install_id=$1",
                "DELETE FROM n_delivery WHERE install_id=$1",
                "DELETE FROM n_group_member WHERE (source,event_id) IN(SELECT source,event_id FROM n_event WHERE interest_id IN(SELECT interest_id FROM n_job_interest WHERE install_id=$1))",
                "DELETE FROM n_event WHERE interest_id IN(SELECT interest_id FROM n_job_interest WHERE install_id=$1)",
                "DELETE FROM n_requester_ticket WHERE EXISTS(SELECT 1 FROM n_job_interest j WHERE j.install_id=$1 AND j.operation_id=n_requester_ticket.operation_id AND j.requester_ref=n_requester_ticket.requester_ref AND j.producer=n_requester_ticket.producer)",
                "DELETE FROM n_job_interest WHERE install_id=$1",
                "DELETE FROM n_interest WHERE install_id=$1",
                "DELETE FROM n_legacy_bridge WHERE install_id=$1",
                "DELETE FROM n_install WHERE install_id=$1",
                "DELETE FROM n_delivery_history WHERE install_id=$1",
                "DELETE FROM push_send_attempts WHERE install_id=$1",
                "DELETE FROM feed_admission_attempts WHERE install_id=$1",
                "DELETE FROM feed_subscriptions WHERE install_id=$1",
                "DELETE FROM devices WHERE install_id=$1",
                "DELETE FROM secure_hello_attempts WHERE install_id=$1",
                "DELETE FROM app_attest_challenges WHERE install_id=$1",
                "DELETE FROM app_attest_keys WHERE install_id=$1",
            ] { writes.push(statement(sql,vec![text(install)],any)); }
            writes
        },
    };
    Plan { statements, after }
}

// Each column is collected from the same source rows; null elements retain their
// declared TEXT/BIGINT type. No chunk can introduce a new commit boundary.
fn bulk(sql: &str, rows: Vec<Vec<Parameter>>) -> Option<Statement> {
    let first = rows.first()?;
    let columns = first.len();
    assert!(rows.iter().all(|r| r.len() == columns));
    let parameters = (0..columns)
        .map(|column| match &first[column] {
            Parameter::Text(_) => Parameter::TextArray(Some(
                rows.iter()
                    .map(|r| match &r[column] {
                        Parameter::Text(v) => v.clone(),
                        _ => unreachable!("fixed text column"),
                    })
                    .collect(),
            )),
            Parameter::Integer(_) => Parameter::IntegerArray(Some(
                rows.iter()
                    .map(|r| match r[column] {
                        Parameter::Integer(v) => v,
                        _ => unreachable!("fixed integer column"),
                    })
                    .collect(),
            )),
            _ => unreachable!("identity bulk families contain only text and integer columns"),
        })
        .collect();
    Some(statement(sql, parameters, CountRule::Any))
}
fn subscriptions(writes: &[SubscriptionWrite]) -> Vec<Statement> {
    let mut feeds = vec![];
    let mut catalog = vec![];
    let mut attempts = vec![];
    let mut upserts = vec![];
    let mut stale = vec![];
    for write in writes {
        match write {
            SubscriptionWrite::EnsureFeed { url, now } => feeds.push(vec![
                text(crate::delivery::wire::hash(&["feed-v1", url])),
                text(url),
                integer(*now),
            ]),
            SubscriptionWrite::PendingFeed { url, source, now } => {
                catalog.push(vec![text(url), text(source), integer(*now)])
            }
            SubscriptionWrite::Attempt { attempt: a } => attempts.push(vec![
                text(&a.id),
                text(&a.install),
                text(&a.key),
                nullable_text(&a.host),
                integer(i64::from(a.accepted)),
                nullable_text(&a.error),
                integer(a.now),
            ]),
            SubscriptionWrite::Upsert {
                install,
                key,
                url,
                enabled,
                now,
            } => upserts.push(vec![
                text(install),
                text(url),
                integer(i64::from(*enabled)),
                integer(*now),
                text(key),
            ]),
            SubscriptionWrite::MarkDeleted {
                install,
                key,
                url,
                now,
            } => stale.push(vec![text(install), text(url), text(key), integer(*now)]),
        }
    }
    [
        bulk("INSERT INTO n_feed(feed_id,canonical_url,epoch,due_at) SELECT x.feed_id,x.url,1,x.now FROM unnest($1::text[],$2::text[],$3::bigint[]) WITH ORDINALITY AS x(feed_id,url,now,ordinal) ORDER BY x.ordinal ON CONFLICT(canonical_url) DO NOTHING",feeds),
        bulk("INSERT INTO n_feed_catalog(feed_url,source_url,created_at,updated_at) SELECT x.url,x.source,x.now,x.now FROM unnest($1::text[],$2::text[],$3::bigint[]) WITH ORDINALITY AS x(url,source,now,ordinal) ORDER BY x.ordinal ON CONFLICT(feed_url) DO NOTHING",catalog),
        bulk("INSERT INTO feed_admission_attempts(attempt_id,install_id,key_id,host,accepted,error_code,created_at) SELECT x.id,x.install,x.key,x.host,x.accepted,x.error,x.now FROM unnest($1::text[],$2::text[],$3::text[],$4::text[],$5::bigint[],$6::text[],$7::bigint[]) WITH ORDINALITY AS x(id,install,key,host,accepted,error,now,ordinal) ORDER BY x.ordinal",attempts),
        bulk("INSERT INTO feed_subscriptions(install_id,feed_url,notifications_enabled,created_at,updated_at,deleted_at) SELECT x.install,x.url,x.enabled,x.now,x.now,NULL FROM unnest($1::text[],$2::text[],$3::bigint[],$4::bigint[],$5::text[]) WITH ORDINALITY AS x(install,url,enabled,now,key,ordinal) WHERE EXISTS(SELECT 1 FROM app_attest_keys WHERE install_id=x.install AND key_id=x.key) ORDER BY x.ordinal ON CONFLICT(install_id,feed_url) DO UPDATE SET created_at=CASE WHEN feed_subscriptions.notifications_enabled=1 AND feed_subscriptions.deleted_at IS NULL THEN feed_subscriptions.created_at ELSE excluded.created_at END,notifications_enabled=excluded.notifications_enabled,updated_at=excluded.updated_at,deleted_at=NULL WHERE feed_subscriptions.notifications_enabled<>excluded.notifications_enabled OR feed_subscriptions.deleted_at IS NOT NULL OR feed_subscriptions.updated_at<=excluded.updated_at-86400",upserts),
        bulk("UPDATE feed_subscriptions s SET notifications_enabled=0,updated_at=x.now,deleted_at=x.now FROM unnest($1::text[],$2::text[],$3::text[],$4::bigint[]) WITH ORDINALITY AS x(install,url,key,now,ordinal) WHERE s.install_id=x.install AND s.feed_url=x.url AND s.deleted_at IS NULL AND EXISTS(SELECT 1 FROM app_attest_keys WHERE install_id=x.install AND key_id=x.key)",stale),
    ].into_iter().flatten().collect()
}
fn decode_identity(row: PostgresRow, read: bool) -> Result<Value> {
    let mut values = Map::new();
    for (index, column) in row.columns().iter().enumerate() {
        let failure = |_| decode_failure(read);
        let value = match *column.type_() {
            PostgresType::TEXT | PostgresType::VARCHAR => {
                json!(row.try_get::<_, Option<String>>(index).map_err(failure)?)
            }
            PostgresType::INT8 => {
                let value = row.try_get::<_, Option<i64>>(index).map_err(failure)?;
                Parameter::Integer(value)
                    .validate()
                    .map_err(|_| decode_failure(read))?;
                json!(value)
            }
            PostgresType::INT4 => json!(row.try_get::<_, Option<i32>>(index).map_err(failure)?),
            PostgresType::BYTEA => {
                json!(row.try_get::<_, Option<Vec<u8>>>(index).map_err(failure)?)
            }
            _ => return Err(decode_failure(read)),
        };
        if values.insert(column.name().into(), value).is_some() {
            return Err(decode_failure(read));
        }
    }
    Ok(Value::Object(values))
}
fn domain_value(operation: &Operation, rows: &[Vec<Value>], counts: &[u64]) -> Result<Value> {
    use Operation::*;
    let read = operation.is_read();
    let first = rows.first().ok_or_else(|| decode_failure(read))?;
    if read && counts.first().copied() != Some(first.len() as u64) {
        return Err(decode_failure(true));
    }
    let count = |rows: &[Value]| -> Result<i64> {
        if rows.is_empty() {
            return Ok(0);
        }
        if rows.len() != 1 {
            return Err(decode_failure(read));
        }
        rows[0]
            .get("count")
            .and_then(Value::as_i64)
            .ok_or_else(|| decode_failure(read))
    };
    let checked = |rows: &[Value], fields: &[&str]| -> Result<()> {
        for row in rows {
            let object = row.as_object().ok_or_else(|| decode_failure(read))?;
            if object.len() != fields.len()
                || fields.iter().any(|field| !object.contains_key(*field))
            {
                return Err(decode_failure(read));
            }
        }
        Ok(())
    };
    match operation {
        GcDeletedSubscriptions { .. } => {
            checked(first, &["count"])?;
            Ok(json!(count(first)?))
        }
        PrunePushAttempts { .. } | PruneSecureAttempts { .. } | PruneAdmissionAttempts { .. } => {
            if rows.iter().any(|rows| !rows.is_empty()) {
                return Err(decode_failure(false));
            }
            Ok(json!(counts
                .first()
                .ok_or_else(|| decode_failure(false))?))
        }
        ReadChallenge { .. } => {
            checked(
                first,
                &[
                    "challenge_hash",
                    "purpose",
                    "install_id",
                    "expires_at",
                    "consumed_at",
                ],
            )?;
            if let Some(row) = first.first() {
                let _: opencast_app_attest_core::app_attest_storage::ChallengeRow =
                    serde_json::from_value(row.clone()).map_err(|_| decode_failure(read))?;
            }
            Ok(first.first().cloned().unwrap_or(Value::Null))
        }
        ReadKey { .. } => {
            checked(
                first,
                &["public_key", "sign_counter", "app_id", "environment"],
            )?;
            if let Some(row) = first.first() {
                let _: opencast_app_attest_core::app_attest_storage::AppAttestKeyRow =
                    serde_json::from_value(row.clone()).map_err(|_| decode_failure(read))?;
            }
            Ok(first.first().cloned().unwrap_or(Value::Null))
        }
        LatestDevice { .. } => {
            checked(first, &["device_token", "device_token_hash"])?;
            if let Some(row) = first.first() {
                let _: crate::storage::DeviceRow =
                    serde_json::from_value(row.clone()).map_err(|_| decode_failure(read))?;
            }
            Ok(first.first().cloned().unwrap_or(Value::Null))
        }
        CountKeys { .. }
        | CountEnabledDevices { .. }
        | CountAdmissions { .. }
        | CountGlobalAdmissions { .. } => {
            checked(first, &["count"])?;
            Ok(json!(count(first)?))
        }
        DeviceExists { .. } | RegistrationReady { .. } => {
            checked(first, &["count"])?;
            Ok(json!(count(first)? > 0))
        }
        IncrementSource { .. } => {
            let last = rows.last().ok_or_else(|| decode_failure(false))?;
            checked(last, &["count"])?;
            Ok(json!(count(last)?))
        }
        IssueChallenge { .. }
        | ConsumeChallenge { .. }
        | AdvanceCounter { .. }
        | RegisterKey { .. } => Ok(json!(counts.first() == Some(&1))),
        FeedSummaries { .. } => {
            checked(
                first,
                &[
                    "feed_url",
                    "title",
                    "consecutive_failures",
                    "last_http_status",
                    "last_error",
                    "last_polled_at",
                ],
            )?;
            let mut output = Map::new();
            for row in first {
                let decoded: crate::storage::FeedSummaryRow =
                    serde_json::from_value(row.clone()).map_err(|_| decode_failure(read))?;
                output.insert(decoded.feed_url, row.clone());
            }
            Ok(Value::Object(output))
        }
        CountHostAdmissions { .. } => {
            checked(first, &["host", "count"])?;
            let mut output = Map::new();
            for row in first {
                let host = row["host"].as_str().ok_or_else(|| decode_failure(read))?;
                let count = row["count"].as_i64().ok_or_else(|| decode_failure(read))?;
                output.insert(host.into(), json!(count));
            }
            Ok(Value::Object(output))
        }
        ReadSubscriptions { .. } => {
            checked(first, &["feed_url"])?;
            for row in first {
                let _: crate::storage::InstallSubscriptionRow =
                    serde_json::from_value(row.clone()).map_err(|_| decode_failure(read))?;
            }
            Ok(Value::Array(first.clone()))
        }
        PruneChallengeSourceBuckets { .. }
        | PruneChallenges { .. }
        | DeleteIdentity { .. }
        | RegisterDevice { .. }
        | DisableDevice { .. }
        | SecureAttempt { .. }
        | PushAttempt { .. }
        | SyncSubscriptions { .. }
        | EraseInstall { .. } => {
            if rows.iter().any(|rows| !rows.is_empty()) {
                return Err(decode_failure(false));
            }
            Ok(Value::Null)
        }
    }
}

pub(in crate::database) async fn reconcile(
    env: &worker::Env,
    operation: &Operation,
    cancel: Cancellation,
    deadline: u64,
) -> Result<Value> {
    use crate::database::slice_c::{recovery_probes, recovery_result, RecoveryProbe as P};
    let probes = recovery_probes(operation)?;
    let started = now();
    if deadline <= started {
        let mut e = Failure::new(Kind::Deadline, Phase::Connect);
        e.outcome = Outcome::NotApplicable;
        return Err(e);
    }
    let connect = Database::connect(env, cancel, started);
    let expiry = delay(deadline - started);
    pin_mut!(connect, expiry);
    let mut db = match select(connect, expiry).await {
        Either::Left((connected, _)) => connected.map_err(|mut error| {
            error.outcome = Outcome::NotApplicable;
            error
        })?,
        Either::Right(((), _)) => {
            let mut e = Failure::new(Kind::Deadline, Phase::Connect);
            e.outcome = Outcome::NotApplicable;
            return Err(e);
        }
    };
    db.cap_deadline(deadline);
    let result=async {
        let mut observations=vec![];
        for probe in probes {
            let (name,sql,parameters)=match probe {
                P::Challenge(id)=>("challenge","SELECT challenge_hash,purpose,install_id,expires_at,consumed_at FROM app_attest_challenges WHERE challenge_id=$1".into(),vec![text(id)]),
                P::Key(install,key)=>("key","SELECT public_key,sign_counter,app_id,environment FROM app_attest_keys WHERE install_id=$1 AND key_id=$2".into(),vec![text(install),text(key)]),
                P::Source(source,start)=>("source_bucket","SELECT request_count AS count FROM app_attest_challenge_source_buckets WHERE source_token=$1 AND window_start=$2".into(),vec![text(source),integer(start)]),
                P::Device(install,hash)=>("device","SELECT install_id,key_id,device_token,device_token_hash,apns_environment,bundle_id,notifications_enabled,last_seen_at,job_capable FROM devices WHERE install_id=$1 AND device_token_hash=$2".into(),vec![text(install),text(hash)]),
                P::Install(install)=>("installation","SELECT * FROM n_install WHERE install_id=$1".into(),vec![text(install)]),
                P::Subscriptions(install,urls)=>("subscriptions","SELECT * FROM feed_subscriptions WHERE install_id=$1 AND feed_url=ANY($2)".into(),vec![text(install),texts(&urls)]),
                P::Interests(install,feeds)=>("interests","SELECT * FROM n_interest WHERE install_id=$1 AND feed_id=ANY($2)".into(),vec![text(install),texts(&feeds)]),
                P::Feeds(urls)=>("feeds","SELECT * FROM n_feed WHERE canonical_url=ANY($1)".into(),vec![texts(&urls)]),
                P::Catalog(urls)=>("catalog","SELECT * FROM n_feed_catalog WHERE feed_url=ANY($1)".into(),vec![texts(&urls)]),
                P::Admissions(ids)=>("admission_attempts","SELECT attempt_id,install_id,key_id,host,accepted,error_code,created_at FROM feed_admission_attempts WHERE attempt_id=ANY($1)".into(),vec![texts(&ids)]),
                P::Secure(id)=>("secure_attempt","SELECT attempt_id,install_id,key_id,accepted,error_code,created_at FROM secure_hello_attempts WHERE attempt_id=$1".into(),vec![text(id)]),
                P::Push(id)=>("push_attempt","SELECT attempt_id,install_id,device_token_hash,apns_environment,apns_status,apns_id,apns_error,created_at FROM push_send_attempts WHERE attempt_id=$1".into(),vec![text(id)]),
                P::DeletionFence(fence)=>("deletion_fence","SELECT fence,expires_at FROM n_deleted_install WHERE fence=$1".into(),vec![text(fence)]),
                P::InstallCount(family,install)=>(family.table(),format!("SELECT COUNT(*) AS count FROM {} WHERE install_id=$1",family.table()),vec![text(install)]),
            };
            let query=Statement {sql,parameters,count:CountRule::Any};query.validate()?;
            let reply=db.read_statement(&query).await?;
            if reply.affected!=reply.rows.len() as u64 {return Err(decode_failure(true));}
            let rows=reply.rows.into_iter().map(|row|decode_identity(row,true)).collect::<Result<Vec<_>>>()?;
            observations.push(json!({"name":name,"rows":rows}));
        }
        Ok(recovery_result(operation,observations))
    }.await;
    let _ = db.finish().await;
    result.map_err(|mut error| {
        error.outcome = Outcome::NotApplicable;
        error
    })
}
