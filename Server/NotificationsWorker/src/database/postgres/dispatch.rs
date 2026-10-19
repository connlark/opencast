//! Dispatch predicates and bulk arrays are authored for PostgreSQL.
use super::super::*;
use crate::{
    database::polling::{AlertMarker, Candidates, ReservationMode},
    polling::policy,
};

const ELIGIBLE:&str="f.admission_paused=0 AND f.no_interest_since IS NULL AND EXISTS(SELECT 1 FROM n_interest j JOIN n_install i ON i.install_id=j.install_id WHERE j.feed_id=f.feed_id AND j.enabled=1 AND i.enabled=1)";
const CONTROLS:&str="EXISTS(SELECT 1 FROM n_control WHERE name='dispatcher_admission' AND enabled=1) AND EXISTS(SELECT 1 FROM n_control WHERE name='feed_observation' AND enabled=1)";
const HEALTHY:&str="f.poll_failures=0 AND f.handling_failures=0 AND f.retry_at<=$1 AND NOT EXISTS(SELECT 1 FROM n_poll_origin h WHERE h.origin_key=f.origin_key AND h.cooldown_until>$1)";
const SCAN_DUE:&str="f.due_at<=$1+30 AND f.retry_at<=$1 AND NOT EXISTS(SELECT 1 FROM n_poll_origin h WHERE h.origin_key=f.origin_key AND h.cooldown_until>$1)";
// Canonical URL authority includes the explicit port and ends at slash/query.
const ORIGIN: &str = "substring(f.canonical_url from '^[^:]+://[^/?]*')";
const PENDING:&str="(EXISTS(SELECT 1 FROM n_observation o WHERE o.feed_id=f.feed_id AND o.state='published' AND o.drain_complete=0 AND o.owner_epoch=f.epoch) OR EXISTS(SELECT 1 FROM n_episode_release r WHERE r.feed_id=f.feed_id AND r.owner_epoch=f.epoch AND r.state IN('ready','pending_future') AND r.eligible_at<=$1 AND r.expires_at>$1) OR EXISTS(SELECT 1 FROM n_outbox x JOIN n_observation o ON o.observation_id=x.observation_id WHERE o.feed_id=f.feed_id AND o.owner_epoch=f.epoch AND x.source='feed_polling' AND x.state='pending' AND x.next_attempt_at<=$1) OR EXISTS(SELECT 1 FROM n_observation o WHERE o.feed_id=f.feed_id AND o.state='staging' AND o.valid_eof=1 AND o.processing_failures<10 AND o.lease_id=f.lease_id AND o.owner_epoch=f.epoch AND o.eligibility_generation=f.eligibility_generation AND o.scan_started_at>$1-604800))";
fn late(seconds: i64) -> String {
    format!("{ELIGIBLE} AND {HEALTHY} AND f.snapshot_key IS NOT NULL AND f.due_at<$1-{seconds}")
}
fn candidates(class: Candidates, now: i64) -> Descriptor {
    let sql=match class {
        Candidates::Repairs => format!("SELECT f.feed_id,f.canonical_url FROM n_feed f WHERE {ELIGIBLE} AND f.dispatch_until>0 AND f.dispatch_until<=$1 AND (({SCAN_DUE}) OR {PENDING}) ORDER BY f.dispatch_until,f.due_at,f.feed_id LIMIT {}",policy::REPAIR_LIMIT),
        Candidates::Maintenance => format!("SELECT f.feed_id,f.canonical_url FROM n_feed f WHERE {ELIGIBLE} AND f.dispatch_until=0 AND {PENDING} ORDER BY f.due_at,f.feed_id LIMIT 100"),
        Candidates::Recurring | Candidates::Baselines => {
            let baseline=if matches!(class,Candidates::Baselines) { "NULL" } else { "NOT NULL" };
            format!("WITH live AS (SELECT {ORIGIN} AS origin,COUNT(*) AS n FROM n_feed f WHERE f.dispatch_until>$1 GROUP BY origin),ranked AS (SELECT f.feed_id,f.canonical_url,f.due_at,{ORIGIN} AS origin,ROW_NUMBER() OVER(PARTITION BY {ORIGIN} ORDER BY f.due_at,f.feed_id) AS host_rank FROM n_feed f WHERE {ELIGIBLE} AND f.dispatch_until=0 AND {SCAN_DUE} AND f.snapshot_key IS {baseline}) SELECT r.feed_id,r.canonical_url FROM ranked r LEFT JOIN live l ON l.origin=r.origin WHERE r.host_rank+COALESCE(l.n,0)<={} ORDER BY r.host_rank,r.due_at,r.feed_id LIMIT {}",policy::ORIGIN_OUTSTANDING_LIMIT,policy::OUTSTANDING_LIMIT)
        }
    };
    statement(sql, vec![integer(now)], CountRule::Any)
}
fn rollup() -> String {
    format!("WITH f AS (SELECT f.due_at,f.snapshot_key,f.dispatch_until,f.last_poll_at,f.last_poll_outcome,({ELIGIBLE}) AS eligible,({HEALTHY}) AS healthy,({SCAN_DUE}) AS scan_due FROM n_feed f) SELECT COUNT(*) FILTER(WHERE eligible AND due_at<=$1) AS overdue,COUNT(*) FILTER(WHERE eligible AND due_at<=$1 AND healthy) AS healthy_overdue,COALESCE(MAX($1-due_at) FILTER(WHERE eligible AND due_at<=$1 AND healthy),0) AS oldest_due_seconds,COUNT(*) FILTER(WHERE eligible AND healthy AND snapshot_key IS NOT NULL AND due_at<$1-600) AS late_600,COUNT(*) FILTER(WHERE eligible AND healthy AND snapshot_key IS NULL AND due_at<$1-600) AS late_baselines,COUNT(*) FILTER(WHERE dispatch_until>$1) AS in_flight,COUNT(*) FILTER(WHERE eligible AND dispatch_until=0 AND scan_due) AS admission_deferred,COUNT(*) FILTER(WHERE last_poll_at>$1-60 AND last_poll_outcome IN('not_modified','unchanged')) AS unchanged_last_minute,COUNT(*) FILTER(WHERE last_poll_at>$1-60 AND last_poll_outcome='published') AS published_last_minute,COUNT(*) FILTER(WHERE last_poll_at>$1-60 AND last_poll_outcome NOT IN('not_modified','unchanged','published')) AS failed_last_minute,COUNT(*) FILTER(WHERE last_poll_at>$1-300 AND last_poll_outcome IN('not_modified','unchanged','published')) AS completed_last_5min FROM f")
}
pub(super) fn describe(operation: &Operation) -> Descriptor {
    use Operation::*;
    let one = CountRule::AtMost(1);
    match operation {
        ReadControl { control } => statement("SELECT enabled FROM n_control WHERE name=$1",vec![text(control.name())],one),
        AbandonIneligible => statement("UPDATE n_observation SET state='abandoned',processing_token=NULL,processing_until=NULL WHERE observation_id IN(SELECT o.observation_id FROM n_observation o JOIN n_feed f ON f.feed_id=o.feed_id WHERE o.state='staging' AND (o.owner_epoch<>f.epoch OR o.eligibility_generation<>f.eligibility_generation OR f.no_interest_since IS NOT NULL) LIMIT 100)",vec![],CountRule::AtMost(100)),
        ReadCandidates { class, now } => candidates(*class,*now),
        ReserveDispatch { candidates, mode, now } => {
            // All three arrays come from the same ordered records. Length and
            // ordinal correspondence are construction invariants, with no cap,
            // deduplication or chunked commits added by this backend.
            let feeds=candidates.iter().map(|c|Some(c.feed_id.clone())).collect();
            let origins=candidates.iter().map(|c|Some(c.origin_key.clone())).collect();
            let authorities=candidates.iter().map(|c|Some(c.admission_origin.clone())).collect();
            statement(format!("WITH input AS (SELECT * FROM unnest($1::text[],$2::text[],$3::text[]) WITH ORDINALITY AS j(feed_id,origin_key,admission_origin,position)),live AS (SELECT {ORIGIN} AS origin,COUNT(*) AS n FROM n_feed f WHERE $6=1 AND f.dispatch_until>$4 GROUP BY origin),eligible AS (SELECT j.*,ROW_NUMBER() OVER(PARTITION BY j.admission_origin ORDER BY j.position) AS origin_rank FROM input j JOIN n_feed f ON f.feed_id=j.feed_id WHERE f.dispatch_until<=$4 AND (f.dispatch_until>0)=($5=1) AND {ELIGIBLE} AND {CONTROLS}),admitted AS (SELECT e.* FROM eligible e LEFT JOIN live l ON l.origin=e.admission_origin WHERE $6=0 OR e.origin_rank+COALESCE(l.n,0)<={} ORDER BY e.position LIMIT(CASE WHEN $6=1 THEN GREATEST(0,{}-(SELECT COUNT(*) FROM n_feed WHERE dispatch_until>$4)) ELSE NULL END)) UPDATE n_feed AS f SET schedule_generation=f.schedule_generation+CASE WHEN f.dispatch_until=0 THEN 1 ELSE 0 END,dispatch_until=$4+{},origin_key=j.origin_key FROM admitted j WHERE f.feed_id=j.feed_id RETURNING f.feed_id,f.epoch,f.schedule_generation,f.due_at",policy::ORIGIN_OUTSTANDING_LIMIT,policy::OUTSTANDING_LIMIT,policy::DISPATCH_RESERVATION_SECONDS),vec![Parameter::TextArray(Some(feeds)),Parameter::TextArray(Some(origins)),Parameter::TextArray(Some(authorities)),integer(*now),integer(i64::from(matches!(mode,ReservationMode::Repair))),integer(i64::from(matches!(mode,ReservationMode::Admission)))],CountRule::AtMost(candidates.len() as u64))
        },
        LapseUncertainEnqueue { identities, now } => {
            let feeds=identities.iter().map(|c|Some(c.feed_id.clone())).collect();
            let generations=identities.iter().map(|c|Some(c.generation)).collect();
            statement(format!("UPDATE n_feed SET dispatch_until=$3 FROM unnest($1::text[],$2::bigint[]) WITH ORDINALITY AS j(feed_id,generation,position) WHERE n_feed.feed_id=j.feed_id AND n_feed.schedule_generation=j.generation AND n_feed.dispatch_until=$3+{}",policy::DISPATCH_RESERVATION_SECONDS),vec![Parameter::TextArray(Some(feeds)),Parameter::IntegerArray(Some(generations)),integer(*now)],CountRule::AtMost(identities.len() as u64))
        },
        ReadRollup { now } => statement(rollup(),vec![integer(*now)],CountRule::Exactly(1)),
        ReadStats { now } => statement(stats(),vec![integer(*now),integer(now.div_euclid(3600)-24)],CountRule::Exactly(1)),
        ReadWatchdog { now } => statement(format!("SELECT (SELECT COUNT(*) FROM n_feed f WHERE {}) AS late_900,(SELECT stall_state FROM n_poll_dispatch WHERE id=1) AS stall_state",late(900)),vec![integer(*now)],CountRule::Exactly(1)),
        ReadDispatchState { full } => statement(if *full { "SELECT stall_state,stall_since,stall_alerted_at,alert_armed_at FROM n_poll_dispatch WHERE id=1" } else { "SELECT stall_state,stall_since FROM n_poll_dispatch WHERE id=1" },vec![],one),
        MarkAlert { marker } => { let (sql,values)=match marker {
            AlertMarker::Armed { now } => ("UPDATE n_poll_dispatch SET alert_armed_at=$1 WHERE id=1 AND alert_armed_at=0",vec![integer(*now)]),
            AlertMarker::Onset { since } => ("UPDATE n_poll_dispatch SET stall_state='stalled',stall_since=$1,stall_alerted_at=0 WHERE id=1 AND stall_state='clear'",vec![integer(*since)]),
            AlertMarker::OnsetSent { since, now } => ("UPDATE n_poll_dispatch SET stall_alerted_at=$1 WHERE id=1 AND stall_state='stalled' AND stall_since=$2 AND stall_alerted_at=0",vec![integer(*now),integer(*since)]),
            AlertMarker::ClaimHourly { since, previous, marker } => ("UPDATE n_poll_dispatch SET stall_alerted_at=$1 WHERE id=1 AND stall_state='stalled' AND stall_since=$2 AND stall_alerted_at=$3",vec![integer(*marker),integer(*since),integer(*previous)]),
            AlertMarker::FinishHourly { expected, value } => ("UPDATE n_poll_dispatch SET stall_alerted_at=$1 WHERE id=1 AND stall_alerted_at=$2",vec![integer(*value),integer(*expected)]),
            AlertMarker::Recovery { since } => ("UPDATE n_poll_dispatch SET stall_state='clear',stall_since=0,stall_alerted_at=0 WHERE id=1 AND stall_state='stalled' AND stall_since=$1",vec![integer(*since)]),
        };statement(sql,values,one) },
        _=>unreachable!("dispatch operation routing"),
    }
}
fn stats() -> String {
    let cooling="EXISTS(SELECT 1 FROM n_poll_origin h WHERE h.origin_key=f.origin_key AND h.cooldown_until>$1)";
    let eligible = format!("{ELIGIBLE} AND f.due_at<=$1");
    let late = late(600);
    // Same liveness roots as snapshot GC, independently expressed for PG.
    let live="s.lease_id IN(SELECT o.lease_id FROM n_observation o WHERE o.state IN('staging','abandoned') AND o.recovery_evidence=1 AND o.valid_eof=1 AND o.scan_started_at>$1-604800) OR EXISTS(SELECT 1 FROM n_feed WHERE snapshot_key=s.object_key) OR EXISTS(SELECT 1 FROM n_observation WHERE snapshot_key=s.object_key AND state='published' AND drain_complete=0) OR EXISTS(SELECT 1 FROM n_snapshot_ref r WHERE r.page_key=s.object_key AND (EXISTS(SELECT 1 FROM n_feed WHERE snapshot_key=r.manifest_key) OR EXISTS(SELECT 1 FROM n_observation WHERE snapshot_key=r.manifest_key AND state='published' AND drain_complete=0))) OR EXISTS(SELECT 1 FROM n_feed f WHERE f.feed_id=s.feed_id AND f.lease_id=s.lease_id AND f.lease_until>$1)";
    format!("SELECT
      (SELECT COUNT(*) FROM n_feed f WHERE {eligible}) AS overdue,
      (SELECT COUNT(*) FROM n_feed f WHERE {eligible} AND {HEALTHY}) AS healthy_overdue,
      (SELECT COALESCE(MAX($1-f.due_at),0) FROM n_feed f WHERE {eligible} AND {HEALTHY}) AS oldest_due_seconds,
      (SELECT COUNT(*) FROM n_feed f WHERE {late}) AS late_600,
      (SELECT COUNT(*) FROM n_feed f WHERE {ELIGIBLE} AND {HEALTHY} AND f.snapshot_key IS NULL AND f.due_at<$1-600) AS late_baselines,
      (SELECT COALESCE(MAX($1-f.due_at),0) FROM n_feed f WHERE {eligible} AND NOT({HEALTHY})) AS oldest_unhealthy_due_seconds,
      (SELECT COUNT(*) FROM n_feed f WHERE {ELIGIBLE} AND f.handling_failures=0 AND (f.poll_failures>0 OR f.retry_at>$1 OR {cooling})) AS publisher_backoff,
      (SELECT COUNT(*) FROM n_feed f WHERE {ELIGIBLE} AND f.handling_failures>0) AS dead_lettered,
      (SELECT COUNT(*) FROM n_feed f WHERE f.dispatch_until>$1) AS in_flight,
      (SELECT COUNT(*) FROM n_feed f WHERE {ELIGIBLE} AND f.dispatch_until>0 AND f.dispatch_until<=$1) AS reservation_expired,
      (SELECT COALESCE(MAX($1-f.due_at),0) FROM n_feed f WHERE f.dispatch_until>$1 AND f.due_at<=$1) AS queue_age_seconds,
      (SELECT COUNT(*) FROM n_poll_origin WHERE cooldown_until>$1) AS origin_cooldowns,
      (SELECT COUNT(*) FROM n_observation WHERE state='abandoned' AND processing_failures>=10) AS preparation_abandoned,
      (SELECT COUNT(*) FROM n_observation WHERE state='abandoned' AND processing_failures<10) AS eligibility_abandoned,
      (SELECT COUNT(*) FROM n_burst WHERE complete=0 AND failures>=10) AS burst_poisoned,
      (SELECT COUNT(*) FROM n_outbox WHERE source='feed_polling' AND state='pending') AS source_pending,
      (SELECT COUNT(*) FROM n_snapshot s WHERE s.state IN('reserved','uploaded','referenced','gc_claimed') AND s.gc_after<=$1 AND NOT({live})) AS snapshot_orphan_total,
      (SELECT COALESCE(SUM(publisher_failures),0)::bigint FROM n_poll_stat WHERE bucket>=$2) AS publisher_failure_total,
      (SELECT COALESCE(SUM(handling_failures),0)::bigint FROM n_poll_stat WHERE bucket>=$2) AS handling_failure_total,
      (SELECT COALESCE(SUM(redeliveries),0)::bigint FROM n_poll_stat WHERE bucket>=$2) AS redelivery_total,
      (SELECT COALESCE(SUM(dead_letters),0)::bigint FROM n_poll_stat WHERE bucket>=$2) AS dead_letter_total,
      (SELECT COALESCE(SUM(stale_commits),0)::bigint FROM n_poll_stat WHERE bucket>=$2) AS stale_commit_total,
      (SELECT COALESCE(SUM(retry_after_clamps),0)::bigint FROM n_poll_stat WHERE bucket>=$2) AS retry_after_clamped_total,
      (SELECT COALESCE(SUM(scan_busy),0)::bigint FROM n_poll_stat WHERE bucket>=$2) AS scan_busy_total,
      (SELECT COALESCE(SUM(permit_reclaims),0)::bigint FROM n_poll_stat WHERE bucket>=$2) AS permit_reclaim_total")
}
