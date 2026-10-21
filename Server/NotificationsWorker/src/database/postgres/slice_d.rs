use super::*;
use crate::database::slice_d::{BurstPage, FanoutPage, Operation};

pub(in crate::database) async fn execute(
    env: &worker::Env,
    operation: &Operation,
    cancel: Cancellation,
    deadline: u64,
    races: Option<&witness::Races>,
) -> Result<Response> {
    crate::database::slice_d::validate(operation)?;
    let started = now();
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
    // Dropping an unfinished connect closes its socket through the owned guard.
    let mut db = open(env, cancel, started, deadline, races)
        .await
        .map_err(classify)?;
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
    for (reply, statement) in results.into_iter().zip(descriptor.statements) {
        if !statement.count.accepts(reply.affected) {
            return Err(decode_failure(read));
        }
        let mut rows = reply
            .rows
            .into_iter()
            .map(|row| decode(row, read))
            .collect::<Result<Vec<_>>>()?;
        let count = if matches!(
            operation,
            Operation::InvalidateEndpoint { .. } | Operation::InvalidateDiagnosticEndpoint { .. }
        ) {
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
    crate::database::slice_d::validate_rows(operation, &replies)?;
    Ok(Response { replies, metrics })
}

fn write(sql: impl Into<String>, parameters: Vec<Parameter>) -> Statement {
    Statement {
        sql: sql.into(),
        parameters,
        count: CountRule::Any,
    }
}
fn texts(values: impl Iterator<Item = String>) -> Parameter {
    Parameter::TextArray(Some(values.map(Some).collect()))
}
fn integers(values: impl Iterator<Item = i64>) -> Parameter {
    Parameter::IntegerArray(Some(values.map(Some).collect()))
}
// D1 meta.changes includes both inherited trigger bodies. The exact endpoint
// predicate selects at most one device and necessarily matches its installation.
// Materialize the trigger predicates under the already-held mutation gate, before
// UPDATE runs n_device_update -> n_install_disable. Count the device and install
// plus every active delivery and issued/registered job interest, including writes
// whose values happen to be unchanged. RETURNING ties that count to an actual
// device update; no match yields zero. The triggers themselves still do the work.
const INVALIDATE_ENDPOINT: &str = "WITH invalidation AS MATERIALIZED (SELECT d.install_id,d.device_token_hash,2+(SELECT COUNT(*) FROM n_delivery x WHERE x.install_id=d.install_id AND x.state IN('pending','leased','uncertain','poisoned'))+(SELECT COUNT(*) FROM n_job_interest j WHERE j.install_id=d.install_id AND j.state IN('issued','registered')) AS d1_changes FROM devices d JOIN n_install i ON i.install_id=d.install_id AND i.token_hash=d.device_token_hash WHERE d.install_id=$1 AND d.device_token_hash=$2 AND i.token_generation=$3 AND i.registered_at<=$4 AND i.registration_revision=$6),changed AS (UPDATE devices d SET device_token='',notifications_enabled=0,last_seen_at=$5 FROM invalidation m WHERE d.install_id=m.install_id AND d.device_token_hash=m.device_token_hash RETURNING m.d1_changes) SELECT COALESCE(SUM(d1_changes),0)::bigint AS d1_changes FROM changed";

fn describe(operation: &Operation) -> Descriptor {
    use Operation::*;
    let any = CountRule::Any;
    match operation {
        RepairFeed { feed } => statement(r#"UPDATE n_feed SET handling_failures=0,retry_at=0,last_poll_error='operator_repair' WHERE feed_id=$1 AND handling_failures>0"#,vec![text(feed)],CountRule::Any),
        RepairBursts { feed,now } => statement(r#"UPDATE n_burst SET failures=0,next_attempt_at=$2,lease_id=NULL,lease_until=NULL WHERE feed_id=$1 AND complete=0 AND failures>=10"#,vec![text(feed),integer(*now)],CountRule::Any),
        ReadFeedRepair { feed } => statement(r#"SELECT feed_id,handling_failures,retry_at,last_poll_error FROM n_feed WHERE feed_id=$1"#,vec![text(feed)],CountRule::AtMost(1)),
        ReadFeedBursts { feed } => statement(r#"SELECT * FROM n_burst WHERE feed_id=$1 ORDER BY presentation_key COLLATE "C""#,vec![text(feed)],CountRule::Any),
ReadEventProgress{source,event}=>statement("SELECT * FROM n_event WHERE source=$1 AND event_id=$2",vec![text(source),text(event)],CountRule::AtMost(1)),
ReadBurstProgress{presentation}=>statement("SELECT * FROM n_burst WHERE presentation_key=$1",vec![text(presentation)],CountRule::AtMost(1)),
ReadDeliveryProgress{delivery}=>statement("SELECT * FROM n_delivery WHERE delivery_id=$1",vec![text(delivery)],CountRule::AtMost(1)),
ReadDrainProgress{observation}=>statement("SELECT * FROM n_observation WHERE observation_id=$1",vec![text(observation)],CountRule::AtMost(1)),
ReadOutboxProgress{event}=>statement("SELECT * FROM n_outbox WHERE source='feed_polling' AND event_id=$1",vec![text(event)],CountRule::AtMost(1)),
ReadCircuitProgress{}=>statement("SELECT * FROM n_circuit WHERE lane='apns'",vec![],CountRule::AtMost(1)),
ReadInstallProgress{install}=>statement("SELECT * FROM n_install WHERE install_id=$1",vec![text(install)],CountRule::AtMost(1)),
ReadDeviceProgress{install,token_hash}=>statement("SELECT install_id,device_token,device_token_hash,apns_environment,bundle_id,notifications_enabled,last_seen_at FROM devices WHERE install_id=$1 AND device_token_hash=$2",vec![text(install),text(token_hash)],CountRule::AtMost(1)),
 ClaimEvent{source,event,lease,now} => statement("UPDATE n_event SET lease_id=$3,lease_until=$4+60 WHERE source=$1 AND event_id=$2 AND fanout_complete=0 AND failures<10 AND expires_at>$4 AND next_attempt_at<=$4 AND (lease_id IS NULL OR lease_until<=$4)",vec![text(source),text(event),text(lease),integer(*now)],any),
 ReadClaimedEvent{source,event,lease} => statement("SELECT * FROM n_event WHERE source=$1 AND event_id=$2 AND lease_id=$3",vec![text(source),text(event),text(lease)],any),
 ReadEpisodeRecipients{feed,occurred_at,cursor,reason,generation,eligible_at,published_at} => statement("SELECT j.install_id,j.generation,i.epoch FROM n_interest j JOIN n_install i ON i.install_id=j.install_id WHERE j.feed_id=$1 AND j.enabled=1 AND i.enabled=1 AND j.install_id>$3 AND CASE WHEN $4 IN('undated','anomalous_date') THEN j.activated_at<=$2 AND j.absence_generation<$5 AND j.absence_at>=j.activated_at AND j.absence_at<=$2 WHEN $4 IN('recent','future') THEN j.activated_at<=$6 AND j.activated_at<=$7 ELSE j.activated_at<=$2 END ORDER BY j.install_id,j.generation LIMIT 100",vec![text(feed),integer(*occurred_at),text(cursor),Parameter::Text(reason.clone()),Parameter::Integer(*generation),integer(*eligible_at),Parameter::Integer(*published_at)],any),
 ReadJobRecipients{interest,cursor,run,generation} => statement("SELECT j.install_id,j.generation,i.epoch FROM n_job_interest j JOIN n_install i ON i.install_id=j.install_id AND i.epoch=j.install_epoch WHERE j.interest_id=$1 AND j.state='registered' AND i.enabled=1 AND i.job_capable=1 AND j.install_id>$2 AND j.run_id=$3 AND j.generation=$4",vec![text(interest),text(cursor),Parameter::Text(run.clone()),Parameter::Integer(*generation)],any),
 ReadRelease{event} => statement("SELECT r.* FROM n_episode_release r WHERE event_id=$1 LIMIT 1",vec![text(event)],any),
 ReadUnreadyBurst{presentation} => statement("SELECT 1 AS \"1\" FROM n_episode_release r JOIN n_observation o ON o.observation_id=r.observation_id LEFT JOIN n_event e ON e.source='feed_polling' AND e.event_id=r.event_id WHERE r.presentation_key=$1 AND (o.drain_complete=0 OR (r.state NOT IN('withdrawn','expired') AND e.event_id IS NULL)) LIMIT 1",vec![text(presentation)],any),
 EnsureBurst{presentation,feed,epoch} => statement("INSERT INTO n_burst(presentation_key,feed_id,owner_epoch) VALUES($1,$2,$3) ON CONFLICT DO NOTHING",vec![text(presentation),text(feed),integer(*epoch)],any),
 ClaimBurst{presentation,lease,now} => statement("UPDATE n_burst SET lease_id=$2,lease_until=$3+180 WHERE presentation_key=$1 AND complete=0 AND failures<10 AND next_attempt_at<=$3 AND (lease_id IS NULL OR lease_until<=$3) AND EXISTS(SELECT 1 FROM n_feed f WHERE f.feed_id=n_burst.feed_id AND f.epoch=n_burst.owner_epoch)",vec![text(presentation),text(lease),integer(*now)],any),
 ReadClaimedBurst{presentation,lease} => statement("SELECT * FROM n_burst WHERE presentation_key=$1 AND lease_id=$2",vec![text(presentation),text(lease)],any),
 ReadBurstRecipient{feed,cursor} => statement("SELECT j.*,i.epoch FROM n_interest j JOIN n_install i ON i.install_id=j.install_id WHERE j.feed_id=$1 AND j.enabled=1 AND i.enabled=1 AND j.install_id>$2 ORDER BY j.install_id LIMIT 1",vec![text(feed),text(cursor)],any),
 ReadBurstMembers{presentation,cursor,activated_at,absence_generation,absence_at,install,now} => statement("SELECT r.event_id,r.eligible_at,r.episode_id,r.expires_at FROM n_episode_release r JOIN n_event e ON e.event_id=r.event_id AND e.source='feed_polling' WHERE r.presentation_key=$1 AND r.event_id>$2 AND e.disposition='accepted' AND ((r.reason IN('undated','anomalous_date') AND $3<=r.first_observed_at AND $4<r.generation AND $5>=$3 AND $5<=r.first_observed_at) OR (r.reason NOT IN('undated','anomalous_date') AND r.eligible_at>=$3 AND r.published_at>=$3)) AND NOT EXISTS(SELECT 1 FROM n_legacy_bridge b WHERE b.install_id=$6 AND b.feed_id=r.feed_id AND b.expires_at>$7 AND b.identity_key IN('episode:'||r.episode_id,'fingerprint:v2:'||r.fingerprint)) ORDER BY r.event_id LIMIT 1000",vec![text(presentation),text(cursor),integer(*activated_at),Parameter::Integer(*absence_generation),Parameter::Integer(*absence_at),text(install),integer(*now)],any),
 FailBurst{presentation,lease,now} => statement("UPDATE n_burst SET failures=failures+1,next_attempt_at=$3+300,lease_id=NULL,lease_until=NULL WHERE presentation_key=$1 AND lease_id=$2",vec![text(presentation),text(lease),integer(*now)],any),
 ReadClaimedDelivery{delivery,lease} => statement("SELECT d.*,e.envelope_json FROM n_delivery d JOIN n_event e ON e.source=d.source AND e.event_id=d.event_id WHERE d.delivery_id=$1 AND d.lease_id=$2 AND d.state='leased'",vec![text(delivery),text(lease)],any),
 ReadEndpoint{install,epoch} => statement("SELECT d.device_token,d.device_token_hash,d.apns_environment,d.bundle_id,i.token_generation,i.registered_at,i.registration_revision FROM n_install i JOIN devices d ON d.install_id=i.install_id AND d.device_token_hash=i.token_hash WHERE i.install_id=$1 AND i.epoch=$2 AND i.enabled=1 AND d.notifications_enabled=1",vec![text(install),integer(*epoch)],any),
 ReadSendAuthority{delivery,generation,source,now,lease,control} => statement("SELECT 1 AS \"1\" FROM n_delivery WHERE delivery_id=$1 AND interest_generation=$2 AND source=$3 AND lease_id=$5 AND state='leased' AND expires_at>$4 AND lease_until>$4 AND attempt_token_generation=(SELECT token_generation FROM n_install WHERE install_id=n_delivery.install_id) AND EXISTS(SELECT 1 FROM n_control WHERE name=$6 AND enabled=1) AND NOT EXISTS(SELECT 1 FROM n_circuit WHERE lane='apns' AND paused=1) AND EXISTS(SELECT 1 FROM n_install i WHERE i.install_id=n_delivery.install_id AND i.epoch=n_delivery.install_epoch AND i.enabled=1 AND (n_delivery.source='feed_polling' OR i.job_capable=1)) AND (EXISTS(SELECT 1 FROM n_interest j JOIN n_feed f ON f.feed_id=j.feed_id WHERE j.install_id=n_delivery.install_id AND j.feed_id=n_delivery.interest_key AND j.generation=n_delivery.interest_generation AND j.enabled=1 AND f.send_paused=0 AND f.epoch=n_delivery.owner_epoch) OR EXISTS(SELECT 1 FROM n_job_interest j WHERE j.interest_id=n_delivery.interest_key AND j.install_id=n_delivery.install_id AND j.install_epoch=n_delivery.install_epoch AND j.generation=n_delivery.interest_generation AND j.state='registered'))",vec![text(delivery),integer(*generation),text(source),integer(*now),text(lease),text(control)],any),
 InvalidateEndpoint{install,token_hash,token_generation,invalidated_at,now,registration_revision} => statement(INVALIDATE_ENDPOINT,vec![text(install),text(token_hash),Parameter::Integer(*token_generation),integer(*invalidated_at),integer(*now),integer(*registration_revision)],CountRule::Exactly(1)),
 MarkStaleToken{delivery,lease,token_generation} => statement("UPDATE n_delivery SET stale_410_generation=$3 WHERE delivery_id=$1 AND lease_id=$2",vec![text(delivery),text(lease),Parameter::Integer(*token_generation)],any),
 ThrottleInstall{install,until} => statement("UPDATE n_install SET next_send_at=GREATEST(next_send_at,$2) WHERE install_id=$1",vec![text(install),integer(*until)],any),
 PauseCircuit{reason,now} => statement("UPDATE n_circuit SET paused=1,reason=$1,updated_at=$2 WHERE lane='apns'",vec![text(reason),integer(*now)],any),
 ReadDiagnosticAuthority{install,token_hash} => statement("SELECT token_generation,registration_revision FROM n_install WHERE install_id=$1 AND token_hash=$2 AND enabled=1 AND NOT EXISTS(SELECT 1 FROM n_circuit WHERE lane='apns' AND paused=1) AND EXISTS(SELECT 1 FROM n_control WHERE name='diagnostic_send' AND enabled=1)",vec![text(install),text(token_hash)],any),
 InvalidateDiagnosticEndpoint{install,token_hash,token_generation,invalidated_at,now,registration_revision} => statement(INVALIDATE_ENDPOINT,vec![text(install),text(token_hash),integer(*token_generation),integer(*invalidated_at),integer(*now),integer(*registration_revision)],CountRule::Exactly(1)),
 ReadDrain{feed} => statement("SELECT o.*,s.sha256,s.bytes FROM n_observation o JOIN n_snapshot s ON s.object_key=o.snapshot_key JOIN n_feed f ON f.feed_id=o.feed_id WHERE o.feed_id=$1 AND o.state='published' AND o.drain_complete=0 AND f.epoch=o.owner_epoch AND f.no_interest_since IS NULL ORDER BY o.generation LIMIT 1",vec![text(feed)],any),
 ReadMatureReleases{feed,now} => statement("SELECT r.* FROM n_episode_release r JOIN n_feed f ON f.feed_id=r.feed_id JOIN n_observation o ON o.observation_id=r.observation_id WHERE r.feed_id=$1 AND r.state IN('ready','pending_future') AND r.eligible_at<=$2 AND o.drain_complete=1 AND f.epoch=r.owner_epoch AND f.no_interest_since IS NULL ORDER BY r.eligible_at,r.episode_id LIMIT 100",vec![text(feed),integer(*now)],any),
 ExpireRelease{event,epoch} => statement("UPDATE n_episode_release SET state='expired',disposition='expired' WHERE event_id=$1 AND EXISTS(SELECT 1 FROM n_episode_release r JOIN n_feed f ON f.feed_id=r.feed_id WHERE r.event_id=$1 AND r.state IN('ready','pending_future') AND f.epoch=r.owner_epoch AND f.epoch=$2 AND f.no_interest_since IS NULL)",vec![text(event),integer(*epoch)],any),
 ReadDueOutbox{feed,now} => statement("SELECT x.* FROM n_outbox x JOIN n_observation o ON o.observation_id=x.observation_id JOIN n_feed f ON f.feed_id=o.feed_id WHERE o.feed_id=$1 AND f.epoch=o.owner_epoch AND x.state='pending' AND x.next_attempt_at<=$2 ORDER BY x.next_attempt_at,x.event_id LIMIT 10",vec![text(feed),integer(*now)],any),
 ExpireOutbox{event} => statement("UPDATE n_outbox SET state='expired',payload_json='{}' WHERE source='feed_polling' AND event_id=$1 AND state='pending'",vec![text(event)],any),
 RetryOutbox{event,next} => statement("UPDATE n_outbox SET next_attempt_at=$2 WHERE source='feed_polling' AND event_id=$1 AND state='pending'",vec![text(event),integer(*next)],any),
 AcceptOutbox{event,receipt} => statement("UPDATE n_outbox SET state='accepted',receipt_id=$2 WHERE source='feed_polling' AND event_id=$1 AND state='pending'",vec![text(event),text(receipt)],any),
 ConflictOutbox{event} => statement("UPDATE n_outbox SET state='conflict' WHERE source='feed_polling' AND event_id=$1 AND state='pending'",vec![text(event)],any),

 Fanout {page} => fanout(page),
 GroupBurst {page} => group_burst(page),
 CompleteBurst {presentation,lease,events_now,burst_now} => Descriptor {statements:vec![
write("UPDATE n_event SET fanout_complete=1 WHERE source='feed_polling' AND event_id IN(SELECT event_id FROM n_episode_release WHERE presentation_key=$1) AND EXISTS(SELECT 1 FROM n_burst b JOIN n_feed f ON f.feed_id=b.feed_id WHERE b.presentation_key=$1 AND b.lease_id=$2 AND b.lease_until>$3 AND b.complete=0 AND f.epoch=b.owner_epoch)",vec![text(presentation),text(lease),integer(*events_now)]),
write("UPDATE n_burst SET complete=1,lease_id=NULL,lease_until=NULL WHERE presentation_key=$1 AND EXISTS(SELECT 1 FROM n_burst b JOIN n_feed f ON f.feed_id=b.feed_id WHERE b.presentation_key=$1 AND b.lease_id=$2 AND b.lease_until>$3 AND b.complete=0 AND f.epoch=b.owner_epoch)",vec![text(presentation),text(lease),integer(*burst_now)]),
 ]},
 ClaimDelivery {delivery,generation,source,now,lease,control} => Descriptor {statements:vec![
write("UPDATE n_delivery SET state='leased',lease_id=$5,lease_until=$4+60,attempt=attempt+1,attempt_started_at=COALESCE(attempt_started_at,$4),attempt_token_generation=(SELECT token_generation FROM n_install WHERE install_id=n_delivery.install_id) WHERE delivery_id=$1 AND interest_generation=$2 AND source=$3 AND state IN('pending','uncertain') AND next_attempt_at<=$4 AND expires_at>$4 AND failures<10 AND EXISTS(SELECT 1 FROM n_control WHERE name=$6 AND enabled=1) AND NOT EXISTS(SELECT 1 FROM n_circuit WHERE lane='apns' AND paused=1) AND EXISTS(SELECT 1 FROM n_install i WHERE i.install_id=n_delivery.install_id AND i.epoch=n_delivery.install_epoch AND i.enabled=1 AND i.next_send_at<=$4 AND (n_delivery.source='feed_polling' OR i.job_capable=1)) AND (EXISTS(SELECT 1 FROM n_interest j JOIN n_feed f ON f.feed_id=j.feed_id WHERE j.install_id=n_delivery.install_id AND j.feed_id=n_delivery.interest_key AND j.generation=n_delivery.interest_generation AND j.enabled=1 AND f.send_paused=0 AND f.epoch=n_delivery.owner_epoch) OR EXISTS(SELECT 1 FROM n_job_interest j WHERE j.interest_id=n_delivery.interest_key AND j.install_id=n_delivery.install_id AND j.install_epoch=n_delivery.install_epoch AND j.generation=n_delivery.interest_generation AND j.state='registered'))",vec![text(delivery),integer(*generation),text(source),integer(*now),text(lease),text(control)]),
write("UPDATE n_install SET next_send_at=$2+1 WHERE install_id=(SELECT install_id FROM n_delivery WHERE delivery_id=$1 AND lease_id=$3)",vec![text(delivery),integer(*now),text(lease)]),
write("UPDATE n_job_interest SET attempt_started_at=COALESCE(attempt_started_at,$2) WHERE interest_id=(SELECT interest_key FROM n_delivery WHERE delivery_id=$1 AND lease_id=$3)",vec![text(delivery),integer(*now),text(lease)]),
 ]},
 FinishDelivery {delivery,lease,state,reason,next,terminal_at} => Descriptor {statements:vec![
write("UPDATE n_delivery SET state=$3,last_reason=$4,next_attempt_at=$5,terminal_at=$6,lease_id=NULL,lease_until=NULL,failures=0 WHERE delivery_id=$1 AND lease_id=$2 AND state='leased'",vec![text(delivery),text(lease),text(state),text(reason),integer(*next),Parameter::Integer(*terminal_at)])]},
 OutboxRelease {event,epoch,observation,digest,occurred_at,expires_at,now,payload} => Descriptor {statements:vec![
write("INSERT INTO n_outbox(source,event_id,observation_id,payload_digest,occurred_at,expires_at,next_attempt_at,state,payload_json) SELECT 'feed_polling',$1,$3,$4,$5,$6,$7,'pending',$8 WHERE EXISTS(SELECT 1 FROM n_episode_release r JOIN n_feed f ON f.feed_id=r.feed_id WHERE r.event_id=$1 AND r.state IN('ready','pending_future') AND f.epoch=r.owner_epoch AND f.epoch=$2 AND f.no_interest_since IS NULL) ON CONFLICT DO NOTHING",vec![text(event),integer(*epoch),text(observation),text(digest),integer(*occurred_at),integer(*expires_at),integer(*now),text(payload.to_string())]),
write("UPDATE n_episode_release SET state='outboxed' WHERE event_id=$1 AND EXISTS(SELECT 1 FROM n_episode_release r JOIN n_feed f ON f.feed_id=r.feed_id WHERE r.event_id=$1 AND r.state IN('ready','pending_future') AND f.epoch=r.owner_epoch AND f.epoch=$2 AND f.no_interest_since IS NULL)",vec![text(event),integer(*epoch)]),
]},
 Drain {feed,observation,generation,epoch,cursor,next,records} => drain(feed,observation,*generation,*epoch,*cursor,*next,records),
 }
}
fn fanout(p: &FanoutPage) -> Descriptor {
    let args = vec![
        text(&p.source),
        text(&p.event),
        text(&p.lease),
        text(&p.cursor),
        text(&p.interest),
        integer(p.expires_at),
        integer(p.now),
        Parameter::Integer(p.owner_epoch),
        Parameter::Text(p.episode_id.clone()),
        Parameter::Text(p.fingerprint.clone()),
        Parameter::Text(p.run.clone()),
        texts(p.recipients.iter().map(|r| r.delivery.clone())),
        texts(p.recipients.iter().map(|r| r.install.clone())),
        integers(p.recipients.iter().map(|r| r.epoch)),
        integers(p.recipients.iter().map(|r| r.generation)),
        texts(p.recipients.iter().map(|r| r.apns.clone())),
    ];
    Descriptor{statements:vec![
write(if p.episode {"WITH p AS (SELECT $1::text AS source,$2::text AS event,$3::text AS lease,$4::text AS cursor,$5::text AS interest,$6::bigint AS expires_at,$7::bigint AS now,$8::bigint AS owner_epoch,$9::text AS episode_id,$10::text AS fingerprint,$11::text AS run), r AS (SELECT * FROM unnest($12::text[],$13::text[],$14::bigint[],$15::bigint[],$16::text[]) WITH ORDINALITY AS x(delivery,install,epoch,generation,apns,ordinal)) INSERT INTO n_delivery(delivery_id,presentation_id,install_id,install_epoch,interest_key,interest_generation,state,expires_at,next_attempt_at,apns_id,collapse_id,source,event_id,owner_epoch) SELECT r.delivery,p.event,r.install,r.epoch,p.interest,r.generation,'pending',p.expires_at,p.now,r.apns,r.delivery,p.source,p.event,p.owner_epoch FROM p CROSS JOIN r WHERE EXISTS(SELECT 1 FROM n_event WHERE source=p.source AND event_id=p.event AND lease_id=p.lease AND lease_until>p.now AND COALESCE(fanout_cursor,'')=p.cursor AND fanout_complete=0) AND EXISTS(SELECT 1 FROM n_install WHERE install_id=r.install AND epoch=r.epoch AND enabled=1) AND EXISTS(SELECT 1 FROM n_interest j JOIN n_feed f ON f.feed_id=j.feed_id WHERE j.install_id=r.install AND j.feed_id=p.interest AND j.generation=r.generation AND j.enabled=1 AND f.epoch=p.owner_epoch) AND NOT EXISTS(SELECT 1 FROM n_legacy_bridge b WHERE b.install_id=r.install AND b.feed_id=p.interest AND b.expires_at>p.now AND b.identity_key IN('episode:'||p.episode_id,'fingerprint:v2:'||p.fingerprint)) ORDER BY r.ordinal ON CONFLICT DO NOTHING"} else {"WITH p AS (SELECT $1::text AS source,$2::text AS event,$3::text AS lease,$4::text AS cursor,$5::text AS interest,$6::bigint AS expires_at,$7::bigint AS now,$8::bigint AS owner_epoch,$9::text AS episode_id,$10::text AS fingerprint,$11::text AS run), r AS (SELECT * FROM unnest($12::text[],$13::text[],$14::bigint[],$15::bigint[],$16::text[]) WITH ORDINALITY AS x(delivery,install,epoch,generation,apns,ordinal)) INSERT INTO n_delivery(delivery_id,presentation_id,install_id,install_epoch,interest_key,interest_generation,state,expires_at,next_attempt_at,apns_id,collapse_id,source,event_id,owner_epoch) SELECT r.delivery,p.event,r.install,r.epoch,p.interest,r.generation,'pending',p.expires_at,p.now,r.apns,r.delivery,p.source,p.event,p.owner_epoch FROM p CROSS JOIN r WHERE EXISTS(SELECT 1 FROM n_event WHERE source=p.source AND event_id=p.event AND lease_id=p.lease AND lease_until>p.now AND COALESCE(fanout_cursor,'')=p.cursor AND fanout_complete=0) AND EXISTS(SELECT 1 FROM n_install WHERE install_id=r.install AND epoch=r.epoch AND enabled=1) AND EXISTS(SELECT 1 FROM n_job_interest j WHERE j.install_id=r.install AND j.interest_id=p.interest AND j.generation=r.generation AND j.state='registered' AND j.run_id=p.run) ORDER BY r.ordinal ON CONFLICT DO NOTHING"},args),
write("INSERT INTO n_delivery_member(delivery_id,source,event_id,install_id,install_epoch,interest_generation) SELECT d.delivery_id,d.source,d.event_id,d.install_id,d.install_epoch,d.interest_generation FROM unnest($1::text[]) WITH ORDINALITY r(delivery,ordinal) JOIN n_delivery d ON d.delivery_id=r.delivery WHERE TRUE AND EXISTS(SELECT 1 FROM n_event WHERE source=$2 AND event_id=$3 AND lease_id=$4) ORDER BY r.ordinal ON CONFLICT DO NOTHING",vec![texts(p.recipients.iter().map(|r|r.delivery.clone())),text(&p.source),text(&p.event),text(&p.lease)]),
write("UPDATE n_event SET fanout_cursor=$4,fanout_complete=$5,lease_id=NULL,lease_until=NULL,next_attempt_at=$6,failures=0 WHERE source=$1 AND event_id=$2 AND lease_id=$3 AND lease_until>$6 AND COALESCE(fanout_cursor,'')=$7",vec![text(&p.source),text(&p.event),text(&p.lease),text(&p.last),integer(i64::from(p.complete)),integer(p.now),text(&p.cursor)]),
]}
}
fn group_burst(p: &BurstPage) -> Descriptor {
    let base = vec![
        text(&p.presentation),
        text(&p.lease),
        integer(p.now),
        text(&p.feed),
        text(&p.install),
        integer(p.generation),
        integer(p.install_epoch),
    ];
    let mut args = base.clone();
    args.extend([
        texts(p.groups.iter().map(|g| g.delivery.clone())),
        texts(p.groups.iter().map(|g| g.presentation.clone())),
        texts(p.groups.iter().map(|g| g.route_event.clone())),
        integers(p.groups.iter().map(|g| g.expires_at)),
        texts(p.groups.iter().map(|g| g.apns.clone())),
        integers(p.groups.iter().map(|_| p.owner_epoch)),
        integers(p.groups.iter().map(|g| g.events.len() as i64)),
    ]);
    let mut statements=vec![
write("WITH p AS (SELECT $1::text AS presentation,$2::text AS lease,$3::bigint AS now,$4::text AS feed,$5::text AS install,$6::bigint AS generation,$7::bigint AS epoch), g AS (SELECT * FROM unnest($8::text[],$9::text[],$10::text[],$11::bigint[],$12::text[],$13::bigint[],$14::bigint[]) WITH ORDINALITY x(delivery,presentation,event,expires_at,apns,owner_epoch,members,ordinal)) INSERT INTO n_delivery(delivery_id,presentation_id,install_id,install_epoch,interest_key,interest_generation,state,expires_at,next_attempt_at,apns_id,collapse_id,source,event_id,owner_epoch,member_count) SELECT g.delivery,g.presentation,p.install,p.epoch,p.feed,p.generation,'pending',g.expires_at,p.now,g.apns,g.delivery,'feed_polling',g.event,g.owner_epoch,g.members FROM p CROSS JOIN g WHERE EXISTS(SELECT 1 FROM n_burst b JOIN n_feed f ON f.feed_id=b.feed_id WHERE b.presentation_key=p.presentation AND b.lease_id=p.lease AND b.lease_until>p.now AND b.complete=0 AND f.epoch=b.owner_epoch) AND EXISTS(SELECT 1 FROM n_interest j JOIN n_install i ON i.install_id=j.install_id WHERE j.feed_id=p.feed AND j.install_id=p.install AND j.generation=p.generation AND j.enabled=1 AND i.epoch=p.epoch AND i.enabled=1) ORDER BY g.ordinal ON CONFLICT DO NOTHING",args)];

    let members = p
        .groups
        .iter()
        .flat_map(|g| {
            g.events
                .iter()
                .enumerate()
                .map(move |(ordinal, event)| (g, event, ordinal as i64))
        })
        .collect::<Vec<_>>();
    let grouped = members
        .iter()
        .filter(|(g, _, _)| g.events.len() > 3)
        .collect::<Vec<_>>();
    if p.groups.iter().any(|g| g.events.len() > 3) {
        let mut args = base.clone();
        args.extend([
            texts(grouped.iter().map(|(g, _, _)| g.delivery.clone())),
            texts(grouped.iter().map(|(g, _, _)| g.presentation.clone())),
            texts(grouped.iter().map(|(_, e, _)| (*e).clone())),
            integers(grouped.iter().map(|(_, _, i)| *i)),
        ]);
        statements.push(write("WITH p AS (SELECT $1::text AS presentation,$2::text AS lease,$3::bigint AS now,$4::text AS feed,$5::text AS install,$6::bigint AS generation,$7::bigint AS epoch), m AS (SELECT * FROM unnest($8::text[],$9::text[],$10::text[],$11::bigint[]) WITH ORDINALITY x(delivery,presentation,event,member_ordinal,input_ordinal)) INSERT INTO n_group_member(group_id,source,event_id,ordinal) SELECT m.presentation,'feed_polling',m.event,m.member_ordinal FROM p CROSS JOIN m WHERE EXISTS(SELECT 1 FROM n_burst b JOIN n_feed f ON f.feed_id=b.feed_id WHERE b.presentation_key=p.presentation AND b.lease_id=p.lease AND b.lease_until>p.now AND b.complete=0 AND f.epoch=b.owner_epoch) AND EXISTS(SELECT 1 FROM n_interest j JOIN n_install i ON i.install_id=j.install_id WHERE j.feed_id=p.feed AND j.install_id=p.install AND j.generation=p.generation AND j.enabled=1 AND i.epoch=p.epoch AND i.enabled=1) AND EXISTS(SELECT 1 FROM n_delivery WHERE delivery_id=m.delivery) ORDER BY m.input_ordinal ON CONFLICT DO NOTHING",args));
    }
    let mut args = base;
    args.extend([
        texts(members.iter().map(|(g, _, _)| g.delivery.clone())),
        texts(members.iter().map(|(g, _, _)| g.presentation.clone())),
        texts(members.iter().map(|(_, e, _)| (*e).clone())),
        integers(members.iter().map(|(_, _, i)| *i)),
    ]);
    statements.push(write("WITH p AS (SELECT $1::text AS presentation,$2::text AS lease,$3::bigint AS now,$4::text AS feed,$5::text AS install,$6::bigint AS generation,$7::bigint AS epoch), m AS (SELECT * FROM unnest($8::text[],$9::text[],$10::text[],$11::bigint[]) WITH ORDINALITY x(delivery,presentation,event,member_ordinal,input_ordinal)) INSERT INTO n_delivery_member(delivery_id,source,event_id,install_id,install_epoch,interest_generation) SELECT m.delivery,'feed_polling',m.event,p.install,p.epoch,p.generation FROM p CROSS JOIN m WHERE EXISTS(SELECT 1 FROM n_burst b JOIN n_feed f ON f.feed_id=b.feed_id WHERE b.presentation_key=p.presentation AND b.lease_id=p.lease AND b.lease_until>p.now AND b.complete=0 AND f.epoch=b.owner_epoch) AND EXISTS(SELECT 1 FROM n_interest j JOIN n_install i ON i.install_id=j.install_id WHERE j.feed_id=p.feed AND j.install_id=p.install AND j.generation=p.generation AND j.enabled=1 AND i.epoch=p.epoch AND i.enabled=1) AND EXISTS(SELECT 1 FROM n_delivery WHERE delivery_id=m.delivery) ORDER BY m.input_ordinal ON CONFLICT DO NOTHING",args));
    statements.push(write("UPDATE n_burst SET cursor=$4,lease_id=NULL,lease_until=NULL,failures=0,next_attempt_at=0 WHERE presentation_key=$1 AND EXISTS(SELECT 1 FROM n_burst b JOIN n_feed f ON f.feed_id=b.feed_id WHERE b.presentation_key=$1 AND b.lease_id=$2 AND b.lease_until>$3 AND b.complete=0 AND f.epoch=b.owner_epoch)",vec![text(&p.presentation),text(&p.lease),integer(p.now),text(&p.install)]));
    Descriptor { statements }
}
fn drain(
    feed: &str,
    observation: &str,
    generation: i64,
    epoch: i64,
    cursor: i64,
    next: i64,
    records: &[crate::database::slice_d::Release],
) -> Descriptor {
    let args = vec![
        text(feed),
        text(observation),
        integer(generation),
        integer(epoch),
        texts(records.iter().map(|r| r.episode_id.clone())),
        texts(records.iter().map(|r| r.event_id.clone())),
        texts(records.iter().map(|r| r.presentation_key.clone())),
        integers(records.iter().map(|r| r.first_observed_at)),
        integers(records.iter().map(|r| r.eligible_at)),
        integers(records.iter().map(|r| r.expires_at)),
        texts(records.iter().map(|r| r.reason.clone())),
        Parameter::TextArray(Some(
            records.iter().map(|r| r.fingerprint.clone()).collect(),
        )),
        Parameter::IntegerArray(Some(records.iter().map(|r| r.published_at).collect())),
        texts(records.iter().map(|r| r.metadata.to_string())),
        texts(records.iter().map(|r| r.state.clone())),
        integer(cursor),
    ];
    Descriptor{statements:vec![
write("WITH r AS (SELECT * FROM unnest($5::text[],$6::text[],$7::text[],$8::bigint[],$9::bigint[],$10::bigint[],$11::text[],$12::text[],$13::bigint[],$14::text[],$15::text[]) WITH ORDINALITY x(episode_id,event_id,presentation_key,first_observed_at,eligible_at,expires_at,reason,fingerprint,published_at,metadata,state,ordinal)) INSERT INTO n_episode_release(feed_id,episode_id,observation_id,generation,owner_epoch,event_id,presentation_key,first_observed_at,eligible_at,expires_at,reason,fingerprint,published_at,metadata_json,state,disposition) SELECT $1,r.episode_id,$2,$3,$4,r.event_id,r.presentation_key,r.first_observed_at,r.eligible_at,r.expires_at,r.reason,r.fingerprint,r.published_at,r.metadata,r.state,CASE WHEN r.state='expired' THEN 'expired' ELSE 'eligible_pending' END FROM r WHERE EXISTS(SELECT 1 FROM n_observation o JOIN n_feed f ON f.feed_id=o.feed_id WHERE o.observation_id=$2 AND o.state='published' AND o.candidate_cursor=$16 AND f.epoch=o.owner_epoch AND f.no_interest_since IS NULL) ORDER BY r.ordinal ON CONFLICT DO NOTHING",args),
write("UPDATE n_observation SET candidate_cursor=$2,drain_complete=CASE WHEN $2=candidate_count THEN 1 ELSE 0 END WHERE observation_id=$1 AND EXISTS(SELECT 1 FROM n_observation o JOIN n_feed f ON f.feed_id=o.feed_id WHERE o.observation_id=$1 AND o.state='published' AND o.candidate_cursor=$3 AND f.epoch=o.owner_epoch AND f.no_interest_since IS NULL)",vec![text(observation),integer(next),integer(cursor)]),
]}
}
