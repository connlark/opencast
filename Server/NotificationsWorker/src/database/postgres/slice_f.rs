use super::*;
use crate::database::slice_f::{FeedAction, Operation};

pub(in crate::database) async fn execute(
    env: &worker::Env,
    operation: &Operation,
    cancel: Cancellation,
    deadline: u64,
) -> Result<Response> {
    crate::database::slice_f::validate(operation)?;
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
    for (reply, statement) in results.into_iter().zip(descriptor.statements) {
        if !statement.count.accepts(reply.affected) {
            return Err(decode_failure(read));
        }
        let rows = reply
            .rows
            .into_iter()
            .map(|row| decode(row, read))
            .collect::<Result<_>>()?;
        replies.push(Reply {
            rows,
            count: reply.affected,
        });
    }
    crate::database::slice_f::validate_rows(operation, &replies)?;
    Ok(Response { replies, metrics })
}

fn optional_text(value: &Option<String>) -> Parameter {
    Parameter::Text(value.clone())
}
fn optional_integer(value: Option<i64>) -> Parameter {
    Parameter::Integer(value)
}
fn describe(operation: &Operation) -> Descriptor {
    use Operation::*;
    let one = CountRule::AtMost(1);
    match operation {
ReadEvent{source,event}=>statement("SELECT * FROM n_event WHERE source=$1 AND event_id=$2",vec![text(source),text(event)],one),
ReadInterest{interest}=>statement("SELECT * FROM n_job_interest WHERE interest_id=$1",vec![text(interest)],one),
InspectFeed{feed}=>statement("SELECT epoch,admission_paused,send_paused,dispatch_until,lease_until,observation_generation,poll_failures,handling_failures,last_poll_outcome,due_at,retry_at FROM n_feed WHERE feed_id=$1",vec![text(feed)],one),
SuppressDeliveries{interest,now}=>statement("UPDATE n_delivery SET state='suppressed',terminal_at=$2,lease_id=NULL,lease_until=NULL,last_reason='interest_cancelled' WHERE interest_key=$1 AND state IN('pending','leased','uncertain','poisoned')",vec![text(interest),integer(*now)],CountRule::Any),
ReadSuppression{interest}=>statement("SELECT COUNT(*) AS remaining FROM n_delivery WHERE interest_key=$1 AND state IN('pending','leased','uncertain','poisoned')",vec![text(interest)],CountRule::Exactly(1)),
RegisterInterest{registration:r}=>statement("UPDATE n_job_interest SET run_id=$7,job_handle=$8,accepted_at=$9,receipt_id=COALESCE(receipt_id,$11),state=CASE WHEN state='seen' THEN 'seen' ELSE 'registered' END WHERE interest_id=$1 AND generation=$2 AND producer=$3 AND operation_id=$4 AND requester_ref=$5 AND grant_digest=$6 AND state IN('issued','registered','seen') AND (run_id IS NULL OR (run_id=$7 AND job_handle=$8 AND accepted_at=$9)) AND $9>=issued_at AND $9<accept_before AND $9<=$10 AND $10<register_before AND EXISTS(SELECT 1 FROM n_install i WHERE i.install_id=n_job_interest.install_id AND i.epoch=n_job_interest.install_epoch AND i.enabled=1 AND i.job_capable=1)",vec![text(&r.interest),integer(r.generation),text(&r.producer),text(&r.operation_id),text(&r.requester_ref),text(&r.grant_digest),text(&r.run_id),text(&r.job_handle),integer(r.accepted_at),integer(r.now),text(&r.receipt)],one),
CancelInterest{cancellation:c}=>statement("UPDATE n_job_interest SET state=CASE WHEN state IN('seen','revoked','superseded','cancelled') THEN state WHEN $8='superseded' THEN 'superseded' ELSE 'cancelled' END,reason=CASE WHEN $8='rejected' THEN 'attachment_rejected' ELSE $8 END,local_fallback_safe=CASE WHEN attempt_started_at IS NULL THEN 1 ELSE 0 END,receipt_id=COALESCE(receipt_id,$9) WHERE interest_id=$1 AND generation=$2 AND producer=$3 AND (($8='rejected' AND grant_digest=$5 AND operation_id=$6 AND requester_ref=$7 AND (run_id IS NULL OR run_id=$4)) OR ($8<>'rejected' AND run_id=$4))",vec![text(&c.interest),integer(c.generation),text(&c.producer),optional_text(&c.run_id),optional_text(&c.grant_digest),optional_text(&c.operation_id),optional_text(&c.requester_ref),text(&c.reason),text(&c.receipt)],one),
ChangeFeed{feed,epoch,now,action}=>{
let assignment=match action{FeedAction::Pause=>"admission_paused=1",FeedAction::PauseSends=>"send_paused=1",FeedAction::ResumeSends=>"send_paused=0",FeedAction::Resume=>"admission_paused=0,lease_id=NULL,lease_until=NULL"};
let gate=if matches!(action,FeedAction::Resume){" AND (lease_id IS NULL OR lease_until<=$3) AND dispatch_until<=$3"}else{""};
statement(format!("UPDATE n_feed SET {assignment} WHERE feed_id=$1 AND epoch=$2 AND $3>=0{gate}"),vec![text(feed),integer(*epoch),integer(*now)],one)},
AdmitEvent{admission:a}=>{let episode=a.kind=="episode";
let gate=if episode{"EXISTS(SELECT 1 FROM n_feed f JOIN n_observation o ON o.feed_id=f.feed_id WHERE f.feed_id=$12 AND f.epoch=$14 AND o.owner_epoch=f.epoch AND o.observation_id=$15 AND o.generation=$16 AND o.state='published') AND EXISTS(SELECT 1 FROM n_control WHERE name='episode_activation' AND enabled=1)"}else{"TRUE"};
let disposition=if episode{"$11"}else{"CASE WHEN $11='suppressed' OR NOT EXISTS(SELECT 1 FROM n_job_interest j JOIN n_install i ON i.install_id=j.install_id AND i.epoch=j.install_epoch WHERE j.interest_id=$13 AND j.generation=$17 AND j.run_id=$18 AND j.state='registered' AND i.enabled=1 AND i.job_capable=1) THEN 'suppressed' ELSE 'accepted' END"};
let mut values=vec![text(&a.source),text(&a.event),text(&a.kind),text(&a.digest),integer(a.occurred_at),integer(a.eligible_at),integer(a.expires_at),text(&a.receipt),text(&a.envelope_json),integer(a.now),text(&a.disposition),optional_text(&a.feed),optional_text(&a.interest),optional_integer(a.epoch),optional_text(&a.observation),optional_integer(a.observation_generation)];
if !episode {values.extend([optional_integer(a.interest_generation),optional_text(&a.run_id)]);}
statement(format!("WITH admission AS (SELECT {disposition} AS disposition) INSERT INTO n_event(source,event_id,schema_version,kind,payload_digest,occurred_at,eligible_at,expires_at,receipt_id,envelope_json,next_attempt_at,disposition,feed_id,interest_id,owner_epoch,fanout_complete,terminal_at) SELECT $1,$2,1,$3,$4,$5,$6,$7,$8,CASE WHEN disposition='suppressed' THEN '{{}}' ELSE $9 END,$10,disposition,$12,$13,$14,CASE WHEN disposition='suppressed' THEN 1 ELSE 0 END,CASE WHEN disposition='suppressed' THEN $10 ELSE NULL END FROM admission WHERE {gate} ON CONFLICT(source,event_id) DO NOTHING"),values,one)},
ReadRollup{now}=>super::dispatch::describe(&crate::database::polling::Operation::ReadRollup{now:*now}),
}
}
