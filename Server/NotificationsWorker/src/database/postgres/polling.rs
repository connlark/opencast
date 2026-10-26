//! Independently authored PostgreSQL polling SQL; no SQLite rewrite at runtime.
use super::super::*;
use crate::database::polling::Fence;

pub(super) fn fence(value: &Fence, values: &mut Vec<Parameter>) -> String {
    let start = values.len() + 1;
    values.extend([
        text(&value.feed),
        integer(value.epoch),
        integer(value.generation),
    ]);
    format!("EXISTS(SELECT 1 FROM n_feed f WHERE f.feed_id=${start} AND f.epoch=${} AND f.schedule_generation=${} AND f.dispatch_until>0 AND f.admission_paused=0 AND f.no_interest_since IS NULL AND EXISTS(SELECT 1 FROM n_interest j JOIN n_install i ON i.install_id=j.install_id WHERE j.feed_id=f.feed_id AND j.enabled=1 AND i.enabled=1) AND EXISTS(SELECT 1 FROM n_control WHERE name='dispatcher_admission' AND enabled=1) AND EXISTS(SELECT 1 FROM n_control WHERE name='feed_observation' AND enabled=1))",start+1,start+2)
}
const PREPARING: &str="EXISTS(SELECT 1 FROM n_observation o WHERE o.feed_id=f.feed_id AND o.state='staging' AND o.valid_eof=1 AND o.processing_failures<10 AND o.lease_id=f.lease_id AND o.owner_epoch=f.epoch AND o.eligibility_generation=f.eligibility_generation AND o.scan_started_at>$4-604800)";
const DRAINING: &str="(EXISTS(SELECT 1 FROM n_observation o WHERE o.feed_id=f.feed_id AND o.state='published' AND o.drain_complete=0 AND o.owner_epoch=f.epoch) OR EXISTS(SELECT 1 FROM n_episode_release r WHERE r.feed_id=f.feed_id AND r.owner_epoch=f.epoch AND r.state IN('ready','pending_future') AND r.eligible_at<=$4 AND r.expires_at>$4))";
const OUTBOXING: &str="EXISTS(SELECT 1 FROM n_outbox x JOIN n_observation o ON o.observation_id=x.observation_id WHERE o.feed_id=f.feed_id AND o.owner_epoch=f.epoch AND x.source='feed_polling' AND x.state='pending' AND x.next_attempt_at<=$4)";

pub(super) fn describe(operation: &Operation) -> Descriptor {
    use Operation::*;
    let one = CountRule::AtMost(1);
    match operation {
        ReadControl { .. } | AbandonIneligible | ReadCandidates { .. } | ReserveDispatch { .. } | LapseUncertainEnqueue { .. } | ReadRollup { .. } | ReadStats { .. } | ReadWatchdog { .. } | ReadDispatchState { .. } | MarkAlert { .. } => super::dispatch::describe(operation),
        Operation::ReadValidators { .. } | Operation::ReadFeedSource { .. } | Operation::ReadScanCheckpoint { .. } | Operation::SettleUnchanged { .. } | Operation::ReadUnchangedFence { .. } | Operation::RecordFailedScan { .. } => super::observations::describe(operation),
        ReadClaim { fence: f, now } => statement(format!("SELECT f.origin_key,f.due_at,f.retry_at,f.baseline_at,f.credible_release_at,f.credible_cadence,f.publish_cadence,f.lease_until,{PREPARING} AS preparing,{DRAINING} AS draining,{OUTBOXING} AS outboxing FROM n_feed f WHERE f.feed_id=$1 AND f.epoch=$2 AND f.schedule_generation=$3 AND f.dispatch_until>0 AND f.admission_paused=0 AND f.no_interest_since IS NULL AND EXISTS(SELECT 1 FROM n_interest j JOIN n_install i ON i.install_id=j.install_id WHERE j.feed_id=f.feed_id AND j.enabled=1 AND i.enabled=1) AND EXISTS(SELECT 1 FROM n_control WHERE name='dispatcher_admission' AND enabled=1) AND EXISTS(SELECT 1 FROM n_control WHERE name='feed_observation' AND enabled=1)"),vec![text(&f.feed),integer(f.epoch),integer(f.generation),integer(*now)],one),
        ReadOrigin { fence: f, origin, .. } => {
            let mut values=vec![text(origin)]; let guard=fence(f,&mut values);
            statement(format!("SELECT COALESCE((SELECT cooldown_until FROM n_poll_origin WHERE origin_key=$1),0) AS cooldown_until,COALESCE((SELECT failures FROM n_poll_origin WHERE origin_key=$1),0) AS failures WHERE {guard}"),values,one)
        },
        RecordOriginFailure { fence: f, origin, until, status, now } => {
            let mut values=vec![text(origin),integer(*until),integer(*status),integer(*now)]; let guard=fence(f,&mut values);
            statement(format!("INSERT INTO n_poll_origin(origin_key,cooldown_until,failures,last_status,updated_at) SELECT $1,$2,1,$3,$4 WHERE {guard} ON CONFLICT(origin_key) DO UPDATE SET cooldown_until=GREATEST(n_poll_origin.cooldown_until,excluded.cooldown_until),failures=LEAST(n_poll_origin.failures+1,12),last_status=excluded.last_status,updated_at=excluded.updated_at"),values,one)
        },
        RecordOriginRecovery { fence: f, origin, status, now } => {
            let mut values=vec![text(origin),integer(*status),integer(*now)]; let guard=fence(f,&mut values);
            statement(format!("UPDATE n_poll_origin SET failures=0,last_status=$2,updated_at=$3 WHERE origin_key=$1 AND failures>0 AND {guard}"),values,one)
        },
        SettlePublisherFailure { fence: f, reason, now } => {
            let mut values=vec![text(&f.feed),integer(*now),text(reason)]; let guard=fence(f,&mut values);
            statement(format!("UPDATE n_feed SET retry_at=$2+LEAST(21600,300*(1::bigint<<LEAST(poll_failures,7)::int)),poll_failures=LEAST(poll_failures+1,12),dispatch_until=0,last_poll_at=$2,last_poll_outcome='publisher_failed',last_poll_error=$3 WHERE feed_id=$1 AND {guard}"),values,one)
        },
        SettleCooldown { fence: f, until, now } => {
            let mut values=vec![text(&f.feed),integer(*until),integer(*now)]; let guard=fence(f,&mut values);
            statement(format!("UPDATE n_feed SET retry_at=GREATEST(retry_at,$2),dispatch_until=0,last_poll_at=$3,last_poll_outcome='origin_cooldown' WHERE feed_id=$1 AND {guard}"),values,one)
        },
        SettleIdle { fence: f, .. } => {
            let mut values=vec![text(&f.feed)]; let guard=fence(f,&mut values);
            statement(format!("UPDATE n_feed SET dispatch_until=0 WHERE feed_id=$1 AND {guard}"),values,one)
        },
        RenewContinuation { fence: f, delay, now } => {
            let mut values=vec![text(&f.feed),integer(now+(*delay).clamp(0,900)+crate::polling::policy::DISPATCH_RESERVATION_SECONDS)]; let guard=fence(f,&mut values);
            statement(format!("UPDATE n_feed SET dispatch_until=$2 WHERE feed_id=$1 AND {guard}"),values,one)
        },
        ReleaseAttempt { fence: f, lease, outcome, reason, now } => {
            let mut values=vec![text(&f.feed),integer(*now),text(outcome),text(reason.chars().take(96).collect::<String>()),Parameter::Text(lease.clone())]; let guard=fence(f,&mut values);
            let idle="NOT EXISTS(SELECT 1 FROM n_observation o WHERE o.lease_id=n_feed.lease_id AND o.state='staging' AND o.valid_eof=1)";
            statement(format!("UPDATE n_feed SET last_poll_at=$2,last_poll_outcome=$3,last_poll_error=$4,lease_until=CASE WHEN lease_id=$5 AND {idle} THEN NULL ELSE lease_until END,lease_id=CASE WHEN lease_id=$5 AND {idle} THEN NULL ELSE lease_id END WHERE feed_id=$1 AND {guard}"),values,one)
        },
        SettleDeadLetter { fence: f, now } => statement("UPDATE n_feed SET retry_at=$4+LEAST(21600,300*(1::bigint<<LEAST(handling_failures,7)::int)),handling_failures=LEAST(handling_failures+1,12),dispatch_until=0,last_poll_at=$4,last_poll_outcome='dead_letter' WHERE feed_id=$1 AND epoch=$2 AND schedule_generation=$3 AND dispatch_until>0",vec![text(&f.feed),integer(f.epoch),integer(f.generation),integer(*now)],one),
        RecordPollStat { counter, now } => { let counter=counter.column(); statement(format!("INSERT INTO n_poll_stat(bucket,{counter}) VALUES($1,1) ON CONFLICT(bucket) DO UPDATE SET {counter}=n_poll_stat.{counter}+1"),vec![integer(now.div_euclid(3600))],CountRule::Exactly(1)) },
    }
}
