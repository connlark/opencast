use super::super::*;
use crate::database::observations::Checkpoint;

fn checkpoint(value: &Checkpoint, now: i64, values: &mut Vec<Parameter>) -> String {
    let start = values.len() + 1;
    values.extend([
        text(&value.feed),
        integer(now),
        integer(value.generation),
        integer(value.epoch),
        integer(value.eligibility),
    ]);
    let mut sql=format!("EXISTS(SELECT 1 FROM n_feed s JOIN n_feed f ON f.feed_id=s.feed_id WHERE s.feed_id=${start} AND (s.lease_id IS NULL OR s.lease_until<=${}) AND s.observation_generation=${} AND f.epoch=${} AND f.eligibility_generation=${} AND f.admission_paused=0 AND f.no_interest_since IS NULL) AND EXISTS(SELECT 1 FROM n_control WHERE name='feed_observation' AND enabled=1)",start+1,start+2,start+3,start+4);
    if let Some(processing) = &value.processing {
        let next = values.len() + 1;
        values.extend([text(&processing.observation), text(&processing.token)]);
        sql+=&format!(" AND EXISTS(SELECT 1 FROM n_observation WHERE observation_id=${next} AND processing_token=${} AND processing_until>${})",next+1,start+1);
    }
    if let Some(poll) = &value.poll {
        sql += &format!(" AND {}", super::polling::fence(poll, values));
    }
    sql
}
const ADMISSIBLE: &str="(s.lease_id IS NULL OR s.lease_until<=$2) AND EXISTS(SELECT 1 FROM n_control WHERE name='feed_observation' AND enabled=1) AND f.admission_paused=0 AND f.no_interest_since IS NULL AND NOT EXISTS(SELECT 1 FROM n_observation o WHERE o.feed_id=f.feed_id AND o.owner_epoch=f.epoch AND ((o.state='published' AND o.drain_complete=0) OR (o.state='staging' AND o.valid_eof=1 AND o.processing_failures<10 AND o.lease_id=s.lease_id AND o.eligibility_generation=f.eligibility_generation AND o.scan_started_at>$2-604800))) AND EXISTS(SELECT 1 FROM n_interest j JOIN n_install i ON i.install_id=j.install_id WHERE j.feed_id=f.feed_id AND j.enabled=1 AND i.enabled=1)";
pub(super) fn describe(operation: &Operation) -> Descriptor {
    use Operation::*;
    let one = CountRule::AtMost(1);
    match operation {
        ReadValidators { feed } => statement("SELECT canonical_url,etag,last_modified,validator_url,validator_at FROM n_feed WHERE feed_id=$1",vec![text(feed)],one),
        ReadFeedSource { url } => statement("SELECT feed_url,source_url,NULL::text AS etag,NULL::text AS last_modified,NULL::text AS validator_url,NULL::bigint AS validator_at FROM n_feed_catalog WHERE feed_url=$1 LIMIT 1",vec![text(url)],one),
        ReadScanCheckpoint { feed, poll, now } => {
            let mut values=vec![text(feed),integer(*now)];
            let poll=poll.as_ref().map(|p|format!(" AND {}",super::polling::fence(p,&mut values))).unwrap_or_default();
            statement(format!("SELECT f.epoch,f.eligibility_generation,s.snapshot_key,s.semantic_digest,s.publish_token,COALESCE(s.observation_generation,0) AS generation FROM n_feed f LEFT JOIN n_feed s ON s.feed_id=f.feed_id WHERE f.feed_id=$1 AND {ADMISSIBLE}{poll}"),values,one)
        },
        ReadUnchangedFence { checkpoint: value, now } => {
            let mut values=vec![]; let guard=checkpoint(value,*now,&mut values);
            statement(format!("SELECT 1 AS \"1\" WHERE {guard}"),values,one)
        },
        RecordFailedScan { bound: b, reservation: r } => Descriptor { statements:vec![
            Statement { sql:"INSERT INTO n_snapshot(object_key,feed_id,owner_epoch,lease_id,sha256,bytes,state,created_at,gc_after) SELECT $3,f.feed_id,f.epoch,$4,'',0,'reserved',$2,$2+604800 FROM n_feed f LEFT JOIN n_feed s ON s.feed_id=f.feed_id WHERE f.feed_id=$1 AND f.epoch=$5 AND f.eligibility_generation=$6 AND COALESCE(s.observation_generation,0)=$7 AND s.publish_token IS NOT DISTINCT FROM $8 AND NOT EXISTS(SELECT 1 FROM n_observation o WHERE o.feed_id=f.feed_id AND o.recovery_evidence=1 AND o.state IN('staging','abandoned') AND o.scan_started_at>=$2-604800 AND o.scan_started_at<=$2)".into(),parameters:vec![text(&b.feed_id),integer(b.started_at),text(&r.snapshot),text(&r.lease),integer(b.epoch),integer(b.eligibility),integer(b.generation),Parameter::Text(b.token.clone())],count:one },
            Statement { sql:"INSERT INTO n_observation(observation_id,feed_id,generation,owner_epoch,lease_id,expected_generation,snapshot_key,scan_started_at,candidate_count,eligibility_generation,state) SELECT $5,f.feed_id,COALESCE(s.observation_generation,0)+1,f.epoch,$4,COALESCE(s.observation_generation,0),$3,$2,0,f.eligibility_generation,'staging' FROM n_feed f LEFT JOIN n_feed s ON s.feed_id=f.feed_id WHERE f.feed_id=$1 AND EXISTS(SELECT 1 FROM n_snapshot WHERE object_key=$3 AND lease_id=$4)".into(),parameters:vec![text(&b.feed_id),integer(b.started_at),text(&r.snapshot),text(&r.lease),text(&r.observation)],count:one },
        ] },
        SettleUnchanged { proof: p, now } => {
            let mut args=vec![Parameter::Text(p.etag.clone()),Parameter::Text(p.modified.clone()),integer(*now),text(&p.token),text(&p.checkpoint.feed),Parameter::Text(p.bound_digest.clone())];
            let valid=if p.bound_digest.is_some() { "snapshot_key IS NOT NULL AND semantic_digest=$6 AND left($6,length(snapshot_key)+1)=snapshot_key||':'" } else { "snapshot_key IS NOT NULL AND $6 IS NULL AND ((etag IS NOT NULL AND etag=$1) OR (etag IS NULL AND last_modified IS NOT NULL AND last_modified=$2))" };
            let schedule=if let Some(s)=&p.schedule {
                args.extend([integer(s.due_at),Parameter::Integer(s.credible_release_at),Parameter::Integer(s.credible_cadence),Parameter::Integer(s.publish_cadence),text(&s.outcome)]);
                ",due_at=$7,retry_at=0,poll_failures=0,handling_failures=0,dispatch_until=0,baseline_at=COALESCE(baseline_at,$3),credible_release_at=COALESCE($8,credible_release_at),credible_cadence=COALESCE($9,credible_cadence),publish_cadence=COALESCE($10,publish_cadence),last_poll_at=$3,last_poll_outcome=$11,last_poll_error=NULL"
            } else { "" };
            let validators=if p.bound_digest.is_some() {
                args.push(Parameter::Text(p.url.clone()));
                format!(",etag=$1,last_modified=$2,validator_url=${},validator_at=$3",args.len())
            } else { String::new() };
            let guard=checkpoint(&p.checkpoint,*now,&mut args);
            Descriptor { statements:vec![
                Statement { sql:format!("UPDATE n_feed SET last_success_at=$3,publish_token=$4{validators}{schedule} WHERE feed_id=$5 AND {valid} AND {guard}"),parameters:args,count:one },
                Statement { sql:"UPDATE n_observation SET recovery_evidence=0 WHERE feed_id=$1 AND scan_started_at<=$2 AND recovery_evidence=1 AND EXISTS(SELECT 1 FROM n_feed WHERE feed_id=$1 AND publish_token=$3)".into(),parameters:vec![text(&p.checkpoint.feed),integer(p.started_at),text(&p.token)],count:CountRule::Any },
                Statement { sql:"UPDATE n_interest SET absence_generation=COALESCE(absence_generation,(SELECT observation_generation FROM n_feed WHERE feed_id=$1)),absence_at=COALESCE(absence_at,$2) WHERE feed_id=$1 AND enabled=1 AND activated_at<=$2 AND (absence_generation IS NULL OR absence_at IS NULL) AND EXISTS(SELECT 1 FROM n_feed WHERE feed_id=$1 AND publish_token=$3)".into(),parameters:vec![text(&p.checkpoint.feed),integer(p.started_at),text(&p.token)],count:CountRule::Any },
            ] }
        },
        _ => unreachable!("observation operation routing"),
    }
}
