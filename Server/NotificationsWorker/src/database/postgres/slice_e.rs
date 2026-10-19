use super::*;
use crate::database::slice_e::Operation;

pub(in crate::database) async fn execute(
    env: &worker::Env,
    operation: &Operation,
    cancel: Cancellation,
    deadline: u64,
) -> Result<Response> {
    crate::database::slice_e::validate(operation)?;
    let started = now();
    if let Operation::AbandonPoisoned { feed, now } = operation {
        return poison::execute(env, feed, *now, cancel, deadline).await;
    }
    let descriptor = describe(operation);
    // Validate before opening a socket or submitting any statement.
    for statement in &descriptor.statements {
        statement.validate()?;
    }
    let read = operation.is_read();
    let classify = |mut error: Failure| {
        if read {
            error.outcome = Outcome::NotApplicable;
        }
        error
    };
    if deadline <= started {
        return Err(classify(Failure::new(Kind::Deadline, Phase::Connect)));
    }
    // Dropping an unfinished connect closes its socket through the owned guard.
    let connect = Database::connect(env, cancel, started);
    let expiry = delay(deadline - started);
    pin_mut!(connect, expiry);
    let mut db = match select(connect, expiry).await {
        Either::Left((connected, _)) => connected.map_err(classify)?,
        Either::Right(((), _)) => {
            return Err(classify(Failure::new(Kind::Deadline, Phase::Connect)));
        }
    };
    db.cap_deadline(deadline);
    let mut metrics = Metrics::default();
    let result = if read {
        db.read_statement(&descriptor.statements[0])
            .await
            .map(|reply| vec![reply])
    } else {
        let gate = Statement {
            sql: GATE.into(),
            parameters: vec![],
            count: CountRule::Exactly(1),
        };
        db.write_transaction(&gate, &descriptor.statements)
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
    // Close before decoding/exposing results or allowing a caller's external I/O.
    // Cleanup cannot undo an acknowledged commit or make Unknown definite.
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
    let results = result?;
    if results.len() != descriptor.statements.len() {
        return Err(decode_failure(read));
    }
    let mut replies = Vec::with_capacity(results.len());
    for (index, (reply, statement)) in results.into_iter().zip(descriptor.statements).enumerate() {
        if !statement.count.accepts(reply.affected) {
            return Err(decode_failure(read));
        }
        let mut rows = reply
            .rows
            .into_iter()
            .map(|row| decode(row, read))
            .collect::<Result<Vec<_>>>()?;
        let count =
            if matches!(operation, Operation::PruneFeeds { .. }) && (index == 0 || index == 2) {
                if rows.len() != 1 || rows[0].as_object().is_none_or(|row| row.len() != 1) {
                    return Err(decode_failure(false));
                }
                let count = rows[0]["d1_changes"]
                    .as_u64()
                    .ok_or_else(|| decode_failure(false))?;
                rows.clear();
                count
            } else {
                reply.affected
            };
        replies.push(Reply { rows, count });
    }
    crate::database::slice_e::readback::normalize(operation, &mut replies)?;
    crate::database::slice_e::validate_rows(operation, &replies)?;
    Ok(Response { replies, metrics })
}

// The mutation gate is already held. Materialize each direct interest match and
// both n_interest_removed trigger predicates before DELETE. The prune selector
// excludes enabled interests, so removing its disabled rows cannot change that
// trigger predicate. Count matched writes even when COALESCE preserves a value.
// RETURNING ties each derived count to an actual deletion; no match returns zero.
const PRUNE_INTERESTS: &str = "WITH matched AS MATERIALIZED (SELECT j.install_id,j.feed_id,1+(SELECT COUNT(*) FROM n_feed f WHERE f.feed_id=j.feed_id)+(SELECT COUNT(*) FROM n_feed f WHERE f.feed_id=j.feed_id AND NOT EXISTS(SELECT 1 FROM n_interest i WHERE i.feed_id=j.feed_id AND i.enabled=1)) AS d1_changes FROM n_interest j WHERE j.feed_id IN(SELECT feed_id FROM n_feed f WHERE no_interest_since<$1 AND NOT EXISTS(SELECT 1 FROM n_interest WHERE feed_id=f.feed_id AND enabled=1) AND NOT EXISTS(SELECT 1 FROM n_event WHERE feed_id=f.feed_id) AND NOT EXISTS(SELECT 1 FROM n_delivery WHERE interest_key=f.feed_id) AND NOT EXISTS(SELECT 1 FROM n_snapshot WHERE feed_id=f.feed_id) AND NOT EXISTS(SELECT 1 FROM n_observation WHERE feed_id=f.feed_id) ORDER BY no_interest_since LIMIT 100)),changed AS (DELETE FROM n_interest j USING matched m WHERE j.install_id=m.install_id AND j.feed_id=m.feed_id RETURNING m.d1_changes) SELECT COALESCE(SUM(d1_changes),0)::bigint AS d1_changes FROM changed";

// D1 also counts n_burst rows removed by the feed foreign-key cascade.
// Capture that cardinality under the gate before the actual feed deletion.
const PRUNE_FEEDS: &str = "WITH matched AS MATERIALIZED (SELECT f.feed_id,1+(SELECT COUNT(*) FROM n_burst b WHERE b.feed_id=f.feed_id) AS d1_changes FROM n_feed f WHERE f.feed_id IN(SELECT feed_id FROM n_feed f WHERE no_interest_since<$1 AND NOT EXISTS(SELECT 1 FROM n_interest WHERE feed_id=f.feed_id AND enabled=1) AND NOT EXISTS(SELECT 1 FROM n_event WHERE feed_id=f.feed_id) AND NOT EXISTS(SELECT 1 FROM n_delivery WHERE interest_key=f.feed_id) AND NOT EXISTS(SELECT 1 FROM n_snapshot WHERE feed_id=f.feed_id) AND NOT EXISTS(SELECT 1 FROM n_observation WHERE feed_id=f.feed_id) ORDER BY no_interest_since LIMIT 100)),changed AS (DELETE FROM n_feed f USING matched m WHERE f.feed_id=m.feed_id RETURNING m.d1_changes) SELECT COALESCE(SUM(d1_changes),0)::bigint AS d1_changes FROM changed";

fn live(alias: &str) -> String {
    // A reused page is protected by *any* live manifest, not only its original
    // upload lease. Abandoned recovery evidence has its own seven-day grace.
    let root = |key: &str| {
        format!("EXISTS(SELECT 1 FROM n_feed WHERE snapshot_key={key}) OR EXISTS(SELECT 1 FROM n_observation WHERE snapshot_key={key} AND state='published' AND drain_complete=0)")
    };
    // Lease IDs are NOT NULL in both tables. Materialize the recovery set once
    // per statement instead of scanning observation history for every object.
    format!("{alias}.lease_id IN(SELECT o.lease_id FROM n_observation o WHERE o.state IN('staging','abandoned') AND o.recovery_evidence=1 AND o.valid_eof=1 AND o.scan_started_at>$1-604800) OR ({}) OR EXISTS(SELECT 1 FROM n_snapshot_ref r WHERE r.page_key={alias}.object_key AND ({})) OR EXISTS(SELECT 1 FROM n_feed f WHERE f.feed_id={alias}.feed_id AND f.lease_id={alias}.lease_id AND f.lease_until>$1)",root(&format!("{alias}.object_key")),root("r.manifest_key"))
}
fn describe(operation: &Operation) -> Descriptor {
    use Operation::*;
    match operation {
        ClaimCleanup { lease,now,generation } => statement(r#"UPDATE n_poll_dispatch SET cleanup_lease=$1,cleanup_until=$2+180 WHERE id=1 AND cleanup_until<=$2 AND cleanup_generation<$3"#,vec![text(lease),integer(*now),integer(*generation)],CountRule::Any),
        PrunePollStats { before } => statement(r#"DELETE FROM n_poll_stat WHERE bucket<$1"#,vec![integer(*before)],CountRule::Any),
        ReleaseCleanup { lease,advance,generation } => statement(r#"UPDATE n_poll_dispatch SET cleanup_lease=NULL,cleanup_until=0,cleanup_generation=CASE WHEN $2<>0 THEN GREATEST(cleanup_generation,$3) ELSE cleanup_generation END WHERE id=1 AND cleanup_lease=$1"#,vec![text(lease),integer(i64::from(*advance)),integer(*generation)],CountRule::Any),
        Readback { after } => Descriptor { statements:vec![crate::database::slice_e::readback::describe(after,true)] },
        FailedEvent { source, event, now, lease } => Descriptor { statements: vec![Statement { sql: r###"UPDATE n_event SET failures=failures+1,next_attempt_at=$3+300,lease_id=NULL,lease_until=NULL WHERE source=$1 AND event_id=$2 AND fanout_complete=0 AND lease_id=$4"###.into(), parameters: vec![text(source), text(event), integer(*now), text(lease)], count: CountRule::Any }] },
        FailedDelivery { delivery, now, lease } => Descriptor { statements: vec![Statement { sql: r###"UPDATE n_delivery SET failures=failures+1,state=CASE WHEN failures>=9 THEN 'poisoned' WHEN state='leased' THEN 'uncertain' ELSE state END,next_attempt_at=$2+300,lease_id=NULL,lease_until=NULL WHERE delivery_id=$1 AND state IN('pending','leased','uncertain') AND lease_id=$3"###.into(), parameters: vec![text(delivery), integer(*now), text(lease)], count: CountRule::Any }] },
        RecoverLeases { now } => Descriptor { statements: vec![Statement { sql: r###"UPDATE n_delivery SET state='uncertain',last_reason='lease_expired',lease_id=NULL,lease_until=NULL,next_attempt_at=$1 WHERE delivery_id IN(SELECT delivery_id FROM n_delivery WHERE state='leased' AND lease_until<=$1 ORDER BY lease_until LIMIT 100)"###.into(), parameters: vec![integer(*now)], count: CountRule::Any }] },
        ExpireDeliveries { now } => Descriptor { statements: vec![Statement { sql: r###"UPDATE n_delivery SET state='expired',terminal_at=$1,last_reason='expired',lease_id=NULL,lease_until=NULL WHERE delivery_id IN(SELECT delivery_id FROM n_delivery WHERE state IN('pending','uncertain','leased','poisoned') AND expires_at<=$1 ORDER BY expires_at LIMIT 100)"###.into(), parameters: vec![integer(*now)], count: CountRule::Any }] },
        ExpireEvents { now } => Descriptor { statements: vec![Statement { sql: r###"UPDATE n_event SET fanout_complete=1,terminal_at=$1,envelope_json='{}',lease_id=NULL,lease_until=NULL WHERE ctid IN(SELECT ctid FROM n_event WHERE fanout_complete=0 AND expires_at<=$1 ORDER BY expires_at LIMIT 100)"###.into(), parameters: vec![integer(*now)], count: CountRule::Any }] },
        ReadDueEvents { now } => Descriptor { statements: vec![Statement { sql: r###"SELECT source,event_id FROM n_event WHERE fanout_complete=0 AND failures<10 AND next_attempt_at<=$1 AND expires_at>$1 AND (lease_id IS NULL OR lease_until<=$1) ORDER BY next_attempt_at LIMIT 100"###.into(), parameters: vec![integer(*now)], count: CountRule::Any }] },
        ReadDueDeliveries { now, episode } => Descriptor { statements: vec![Statement { sql: format!(r###"SELECT delivery_id,source,interest_generation FROM n_delivery WHERE source IN({sources}) AND state IN('pending','uncertain') AND failures<10 AND next_attempt_at<=$1 AND expires_at>$1{paused_clause} ORDER BY next_attempt_at LIMIT 100"###, sources=if *episode { "'feed_polling'" } else { "'ad_analysis','remote_transcription'" }, paused_clause=if *episode { r###" AND NOT EXISTS(SELECT 1 FROM n_feed f WHERE f.feed_id=n_delivery.interest_key AND f.send_paused=1)"### } else { "" }), parameters: vec![integer(*now)], count: CountRule::Any }] },
        TerminalizeEvents { now } => Descriptor { statements: vec![Statement { sql: r###"UPDATE n_event SET terminal_at=$1,envelope_json='{}' WHERE ctid IN(SELECT e.ctid FROM n_event e WHERE e.fanout_complete=1 AND e.terminal_at IS NULL AND NOT EXISTS(SELECT 1 FROM n_delivery d WHERE d.source=e.source AND d.event_id=e.event_id AND d.state IN('pending','leased','uncertain','poisoned')) LIMIT 100)"###.into(), parameters: vec![integer(*now)], count: CountRule::Any }] },
        ExpireDeletedInstalls { now } => Descriptor { statements: vec![Statement { sql: r###"DELETE FROM n_deleted_install WHERE fence IN(SELECT fence FROM n_deleted_install WHERE expires_at<=$1 LIMIT 100)"###.into(), parameters: vec![integer(*now)], count: CountRule::Any }] },
        ReadTerminalEvents { before } => Descriptor { statements: vec![Statement { sql: r###"SELECT source,event_id FROM n_event WHERE terminal_at<$1 ORDER BY terminal_at LIMIT 20"###.into(), parameters: vec![integer(*before)], count: CountRule::Any }] },
        RetireEvent { source, event } => Descriptor { statements: vec![Statement { sql: r###"DELETE FROM n_delivery_member WHERE source=$1 AND event_id=$2"###.into(), parameters: vec![text(source), text(event)], count: CountRule::Any }, Statement { sql: r###"DELETE FROM n_delivery WHERE source=$1 AND event_id=$2 AND state NOT IN('pending','leased','uncertain','poisoned')"###.into(), parameters: vec![text(source), text(event)], count: CountRule::Any }, Statement { sql: r###"DELETE FROM n_group_member WHERE source=$1 AND event_id=$2"###.into(), parameters: vec![text(source), text(event)], count: CountRule::Any }, Statement { sql: r###"DELETE FROM n_event WHERE source=$1 AND event_id=$2 AND NOT EXISTS(SELECT 1 FROM n_delivery WHERE source=$1 AND event_id=$2)"###.into(), parameters: vec![text(source), text(event)], count: CountRule::Any }] },
        ExpireLegacyBridges { now } => Descriptor { statements: vec![Statement { sql: r###"DELETE FROM n_legacy_bridge WHERE ctid IN(SELECT ctid FROM n_legacy_bridge WHERE expires_at<=$1 LIMIT 100)"###.into(), parameters: vec![integer(*now)], count: CountRule::Any }] },
        ExpireTickets { now } => Descriptor { statements: vec![Statement { sql: r###"DELETE FROM n_requester_ticket WHERE ticket_digest IN(SELECT ticket_digest FROM n_requester_ticket WHERE expires_at<=$1 LIMIT 100)"###.into(), parameters: vec![integer(*now)], count: CountRule::Any }] },
        RetireJobInterests { before } => Descriptor { statements: vec![Statement { sql: r###"DELETE FROM n_job_interest WHERE ctid IN(SELECT ctid FROM n_job_interest j WHERE register_before<$1 AND NOT EXISTS(SELECT 1 FROM n_event WHERE interest_id=j.interest_id) AND NOT EXISTS(SELECT 1 FROM n_delivery WHERE interest_key=j.interest_id) LIMIT 100)"###.into(), parameters: vec![integer(*before)], count: CountRule::Any }] },
        PruneFeeds { before } => Descriptor { statements: vec![Statement { sql: PRUNE_INTERESTS.into(), parameters: vec![integer(*before)], count: CountRule::Exactly(1) }, Statement { sql: r###"DELETE FROM n_legacy_bridge WHERE feed_id IN(SELECT feed_id FROM n_feed f WHERE no_interest_since<$1 AND NOT EXISTS(SELECT 1 FROM n_interest WHERE feed_id=f.feed_id AND enabled=1) AND NOT EXISTS(SELECT 1 FROM n_event WHERE feed_id=f.feed_id) AND NOT EXISTS(SELECT 1 FROM n_delivery WHERE interest_key=f.feed_id) AND NOT EXISTS(SELECT 1 FROM n_snapshot WHERE feed_id=f.feed_id) AND NOT EXISTS(SELECT 1 FROM n_observation WHERE feed_id=f.feed_id) ORDER BY no_interest_since LIMIT 100)"###.into(), parameters: vec![integer(*before)], count: CountRule::Any }, Statement { sql: PRUNE_FEEDS.into(), parameters: vec![integer(*before)], count: CountRule::Exactly(1) }] },
        ReadDeliverySummary => Descriptor { statements: vec![Statement { sql: r###"SELECT state,COUNT(*) AS count,MIN(next_attempt_at) AS oldest_due FROM n_delivery WHERE state IN('pending','uncertain','leased','poisoned') GROUP BY state ORDER BY state"###.into(), parameters: vec![], count: CountRule::Any }] },
        ReadEventSummary => Descriptor { statements: vec![Statement { sql: r###"SELECT COUNT(*) AS count,MIN(next_attempt_at) AS oldest_due,SUM(CASE WHEN failures>=10 THEN 1 ELSE 0 END) AS poisoned FROM n_event WHERE fanout_complete=0"###.into(), parameters: vec![], count: CountRule::AtMost(1) }] },
        ReadCircuit => Descriptor { statements: vec![Statement { sql: r###"SELECT paused,reason,updated_at FROM n_circuit WHERE lane='apns'"###.into(), parameters: vec![], count: CountRule::AtMost(1) }] },
        ReadFeedDeliveries { feed, now } => Descriptor { statements: vec![Statement { sql: r###"SELECT delivery_id,source,interest_generation FROM n_delivery WHERE interest_key=$1 AND source='feed_polling' AND state IN('pending','uncertain') AND failures<10 AND next_attempt_at<=$2 AND expires_at>$2 AND NOT EXISTS(SELECT 1 FROM n_feed f WHERE f.feed_id=n_delivery.interest_key AND f.send_paused=1) ORDER BY next_attempt_at LIMIT 100"###.into(), parameters: vec![text(feed), integer(*now)], count: CountRule::Any }] },
        ExpireFeedHistory { now } => Descriptor { statements: vec![Statement { sql: r###"UPDATE n_observation SET drain_complete=1,recovery_evidence=0 WHERE feed_id IN(SELECT feed_id FROM n_feed f WHERE no_interest_since<=$1-2592000 AND NOT EXISTS(SELECT 1 FROM n_interest j WHERE j.feed_id=f.feed_id AND j.enabled=1) AND (f.lease_id IS NULL OR f.lease_until<=$1) ORDER BY no_interest_since,feed_id COLLATE "C" LIMIT 20)"###.into(), parameters: vec![integer(*now)], count: CountRule::Any }, Statement { sql: r###"DELETE FROM n_episode_release WHERE feed_id IN(SELECT feed_id FROM n_feed f WHERE no_interest_since<=$1-2592000 AND NOT EXISTS(SELECT 1 FROM n_interest j WHERE j.feed_id=f.feed_id AND j.enabled=1) AND (f.lease_id IS NULL OR f.lease_until<=$1) ORDER BY no_interest_since,feed_id COLLATE "C" LIMIT 20)"###.into(), parameters: vec![integer(*now)], count: CountRule::Any }, Statement { sql: r###"UPDATE n_feed SET snapshot_key=NULL,observation_generation=0,semantic_digest=NULL,etag=NULL,last_modified=NULL,validator_url=NULL,validator_at=NULL,publish_token=NULL,lease_id=NULL,lease_until=NULL,baseline_at=NULL,credible_release_at=NULL,credible_cadence=NULL,retry_at=0,poll_failures=0 WHERE feed_id IN(SELECT feed_id FROM n_feed f WHERE no_interest_since<=$1-2592000 AND NOT EXISTS(SELECT 1 FROM n_interest j WHERE j.feed_id=f.feed_id AND j.enabled=1) AND (f.lease_id IS NULL OR f.lease_until<=$1) ORDER BY no_interest_since,feed_id COLLATE "C" LIMIT 20)"###.into(), parameters: vec![integer(*now)], count: CountRule::Any }] },
        ExpireOutbox { now } => Descriptor { statements: vec![Statement { sql: r###"UPDATE n_outbox SET state='expired',payload_json='{}' WHERE ctid IN(SELECT ctid FROM n_outbox WHERE source='feed_polling' AND expires_at<=$1 AND state='pending' LIMIT 1000)"###.into(), parameters: vec![integer(*now)], count: CountRule::Any }] },
        ScrubOutbox { now } => Descriptor { statements: vec![Statement { sql: r###"UPDATE n_outbox SET payload_json='{}' WHERE ctid IN(SELECT ctid FROM n_outbox WHERE source='feed_polling' AND expires_at<=$1 AND state<>'pending' AND payload_json<>'{}' LIMIT 1000)"###.into(), parameters: vec![integer(*now)], count: CountRule::Any }] },
        RetireOutbox { now } => Descriptor { statements: vec![Statement { sql: r###"DELETE FROM n_outbox WHERE ctid IN(SELECT ctid FROM n_outbox WHERE source='feed_polling' AND expires_at<=$1-604800 AND state<>'pending' LIMIT 1000)"###.into(), parameters: vec![integer(*now)], count: CountRule::Any }] },
        RetireReleases { now } => Descriptor { statements: vec![Statement { sql: r###"DELETE FROM n_episode_release WHERE ctid IN(SELECT ctid FROM n_episode_release WHERE expires_at<=$1-604800 LIMIT 1000)"###.into(), parameters: vec![integer(*now)], count: CountRule::Any }] },
        RetireBursts => Descriptor { statements: vec![Statement { sql: r###"DELETE FROM n_burst WHERE ctid IN(SELECT ctid FROM n_burst WHERE NOT EXISTS(SELECT 1 FROM n_episode_release r WHERE r.presentation_key=n_burst.presentation_key) LIMIT 1000)"###.into(), parameters: vec![], count: CountRule::Any }] },
        ReadGcCandidates { now, limit } => Descriptor { statements: vec![Statement { sql: format!(r###"SELECT object_key FROM n_snapshot s WHERE s.state IN('reserved','uploaded','referenced','gc_claimed') AND s.gc_after<=$1 AND NOT({live}) ORDER BY s.gc_after,s.object_key COLLATE "C" LIMIT {}"###, limit.min(&200), live=live("s")), parameters: vec![integer(*now)], count: CountRule::Any }] },
        ClaimGc { now, key } => Descriptor { statements: vec![Statement { sql: format!(r###"UPDATE n_snapshot AS s SET state='gc_claimed' WHERE object_key=$2 AND state IN('reserved','uploaded','referenced','gc_claimed') AND gc_after<=$1 AND NOT({live})"###, live=live("s")), parameters: vec![integer(*now), text(key)], count: CountRule::Any }] },
        ReadGcClaim { now, key } => Descriptor { statements: vec![Statement { sql: format!(r###"SELECT object_key FROM n_snapshot s WHERE object_key=$2 AND state='gc_claimed' AND NOT({live})"###, live=live("s")), parameters: vec![integer(*now), text(key)], count: CountRule::AtMost(1) }] },
        MarkDeleted { key } => Descriptor { statements: vec![Statement { sql: r###"UPDATE n_snapshot SET state='deleted' WHERE object_key=$1 AND state='gc_claimed'"###.into(), parameters: vec![text(key)], count: CountRule::Any }] },
        RetireObservations { now } => Descriptor { statements: vec![Statement { sql: r###"DELETE FROM n_observation WHERE observation_id IN(SELECT o.observation_id FROM n_observation o WHERE o.scan_started_at<=$1-604800 AND (o.state<>'published' OR o.drain_complete=1) AND NOT EXISTS(SELECT 1 FROM n_feed f WHERE f.snapshot_key=o.snapshot_key) AND o.lease_id NOT IN(SELECT f.lease_id FROM n_feed f WHERE f.lease_until>$1) AND NOT EXISTS(SELECT 1 FROM n_episode_release r WHERE r.observation_id=o.observation_id) AND NOT EXISTS(SELECT 1 FROM n_outbox x WHERE x.observation_id=o.observation_id) LIMIT 1000)"###.into(), parameters: vec![integer(*now)], count: CountRule::Any }] },
        RetireSnapshotRefs => Descriptor { statements: vec![Statement { sql: r###"DELETE FROM n_snapshot_ref WHERE manifest_key IN(SELECT object_key FROM n_snapshot s WHERE state='deleted' AND NOT EXISTS(SELECT 1 FROM n_observation o WHERE o.snapshot_key=s.object_key) LIMIT 1000)"###.into(), parameters: vec![], count: CountRule::Any }] },
        RetireSnapshots => Descriptor { statements: vec![Statement { sql: r###"DELETE FROM n_snapshot WHERE object_key IN(SELECT object_key FROM n_snapshot s WHERE state='deleted' AND NOT EXISTS(SELECT 1 FROM n_snapshot_ref r WHERE r.manifest_key=s.object_key) AND NOT EXISTS(SELECT 1 FROM n_snapshot_ref r WHERE r.page_key=s.object_key) AND NOT EXISTS(SELECT 1 FROM n_observation o WHERE o.snapshot_key=s.object_key) LIMIT 2000)"###.into(), parameters: vec![], count: CountRule::Any }] },
        AbandonPoisoned { .. } => unreachable!("poison JSON is handled inside its gated transaction"),
    }
}

mod poison {
    macro_rules! query {
        ($db:expr, $sql:expr, $params:expr, $phase:expr) => {
            $db.typed($sql, $params).await.map_err(|mut error| {
                error.phase = $phase;
                error.outcome = if error.sqlstate.is_some() {
                    Outcome::NotCommitted
                } else {
                    Outcome::Unknown
                };
                error
            })
        };
    }
    use super::*;

    fn invalid_json() -> Failure {
        let mut failure = Failure::new(Kind::Database, Phase::Transaction);
        failure.outcome = Outcome::NotCommitted;
        failure
    }

    pub(super) async fn execute(
        env: &worker::Env,
        feed: &str,
        timestamp: i64,
        cancel: Cancellation,
        deadline: u64,
    ) -> Result<Response> {
        let started = now();
        if deadline <= started {
            return Err(Failure::new(Kind::Deadline, Phase::Connect));
        }
        let connect = Database::connect(env, cancel, started);
        let expiry = delay(deadline - started);
        pin_mut!(connect, expiry);
        let mut db = match select(connect, expiry).await {
            Either::Left((connected, _)) => connected?,
            Either::Right(((), _)) => return Err(Failure::new(Kind::Deadline, Phase::Connect)),
        };
        db.cap_deadline(deadline);
        let transaction_started = now();
        db.cap_deadline(
            transaction_started
                .saturating_add(opencast_worker_database_core::lifecycle::TRANSACTION_MS),
        );
        let result: Result<(u64,u64,i64,u64)> = async {
        query!(&mut db, "BEGIN", &[], Phase::Transaction)?;
        let gate_started=now();
        let gate = query!(&mut db, GATE, &[], Phase::Transaction)?;
        let gate_wait_us: i64 = gate.first().ok_or_else(|| decode_failure(false))?.try_get("gate_wait_us").map_err(|_| decode_failure(false))?;
        let gate_reply_ms=now().saturating_sub(gate_started);
        let selected = query!(&mut db, "SELECT observation_id,reason_counts_json FROM n_observation WHERE feed_id=$1 AND state='staging' AND valid_eof=1 AND processing_failures>=10 AND (processing_token IS NULL OR processing_until<=$2) ORDER BY scan_started_at LIMIT 20", &[(&feed, PostgresType::TEXT), (&timestamp, PostgresType::INT8)], Phase::Transaction)?;
        let mut ids: Vec<String> = Vec::with_capacity(selected.len());
        let mut counts: Vec<String> = Vec::with_capacity(selected.len());
        for row in selected {
            let id: String = row.try_get("observation_id").map_err(|_| decode_failure(false))?;
            let value: String = row.try_get("reason_counts_json").map_err(|_| decode_failure(false))?;
            ids.push(id); counts.push(retention_json::set_poisoned(&value).map_err(|_| invalid_json())?);
        }
        // One bulk UPDATE preserves the first source statement's affected count.
        let first = query!(&mut db, "UPDATE n_observation o SET state='abandoned',completed_at=$3,processing_token=NULL,processing_until=NULL,reason_counts_json=j.value FROM unnest($1::text[],$2::text[]) j(id,value) WHERE o.observation_id=j.id RETURNING o.observation_id", &[(&ids,PostgresType::TEXT_ARRAY),(&counts,PostgresType::TEXT_ARRAY),(&timestamp,PostgresType::INT8)], Phase::Transaction)?;
        // Re-evaluate after the first update, including already-abandoned rows.
        // SQLite chooses the first duplicate property; json/jsonb -> chooses a
        // different duplicate, so use the same lexical reader for this fence.
        let abandoned = query!(&mut db, "SELECT lease_id,reason_counts_json FROM n_observation WHERE feed_id=$1 AND state='abandoned' AND processing_failures>=10", &[(&feed,PostgresType::TEXT)], Phase::Transaction)?;
        let mut leases: Vec<String> = Vec::new();
        for row in abandoned {
            let value: String = row.try_get("reason_counts_json").map_err(|_| decode_failure(false))?;
            if retention_json::is_poisoned(&value).map_err(|_| invalid_json())? {
                leases.push(row.try_get("lease_id").map_err(|_| decode_failure(false))?);
            }
        }
        let second = query!(&mut db, "UPDATE n_feed SET lease_id=NULL,lease_until=NULL WHERE feed_id=$1 AND lease_id=ANY($2::text[]) RETURNING feed_id", &[(&feed,PostgresType::TEXT),(&leases,PostgresType::TEXT_ARRAY)], Phase::Transaction)?;
        query!(&mut db, "COMMIT", &[], Phase::Commit)?;
        Ok((first.len() as u64, second.len() as u64, gate_wait_us, gate_reply_ms))
    }.await;
        if result.is_err() {
            // Best-effort rollback never changes the initiating outcome. The owned
            // transport closes below even if the bounded rollback cannot run.
            let _rollback = query!(&mut db, "ROLLBACK", &[], Phase::Transaction);
        }
        let transaction_ms = now().saturating_sub(transaction_started);
        let (_spans, _cleanup) = db.finish().await;
        let (first, second, gate_wait_us, gate_reply_ms) = result?;
        Ok(Response {
            replies: vec![
                Reply {
                    rows: vec![],
                    count: first,
                },
                Reply {
                    rows: vec![],
                    count: second,
                },
            ],
            metrics: Metrics {
                handler_ms: now().saturating_sub(started),
                transaction_ms,
                gate_wait_us: Some(gate_wait_us),
                gate_reply_ms: Some(gate_reply_ms),
            },
        })
    }

    use crate::slice_e_json as retention_json;
}
