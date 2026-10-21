use super::*;
use crate::database::slice_b::{Operation, Scan};

pub(in crate::database) async fn execute(
    env: &worker::Env,
    operation: &Operation,
    cancel: Cancellation,
    deadline: u64,
    races: Option<&witness::Races>,
) -> Result<Response> {
    crate::database::slice_b::validate(operation)?;
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
    crate::database::slice_b::validate_rows(operation, &replies)?;
    Ok(Response { replies, metrics })
}

fn texts(values: impl Iterator<Item = String>) -> Parameter {
    Parameter::TextArray(Some(values.map(Some).collect()))
}
fn integers(values: impl Iterator<Item = i64>) -> Parameter {
    Parameter::IntegerArray(Some(values.map(Some).collect()))
}
fn fence(scan: &Scan, now: i64, values: &mut Vec<Parameter>) -> String {
    let c = &scan.checkpoint;
    let start = values.len() + 1;
    values.extend([
        text(&c.feed),
        integer(now),
        integer(c.generation),
        integer(c.epoch),
        integer(c.eligibility),
    ]);
    let lease = if let Some(lease) = &scan.lease {
        values.push(text(lease));
        format!(
            "s.lease_id=${} AND s.lease_until>${}",
            values.len(),
            start + 1
        )
    } else {
        format!("(s.lease_id IS NULL OR s.lease_until<=${})", start + 1)
    };
    let mut sql=format!("EXISTS(SELECT 1 FROM n_feed s JOIN n_feed f ON f.feed_id=s.feed_id WHERE s.feed_id=${start} AND {lease} AND s.observation_generation=${} AND f.epoch=${} AND f.eligibility_generation=${} AND f.admission_paused=0 AND f.no_interest_since IS NULL) AND EXISTS(SELECT 1 FROM n_control WHERE name='feed_observation' AND enabled=1)",start+2,start+3,start+4);
    if let Some(p) = &c.processing {
        let next = values.len() + 1;
        values.extend([text(&p.observation), text(&p.token)]);
        sql+=&format!(" AND EXISTS(SELECT 1 FROM n_observation WHERE observation_id=${next} AND processing_token=${} AND processing_until>${})",next+1,start+1);
    }
    if let Some(p) = &c.poll {
        sql += &format!(" AND {}", super::polling::fence(p, values));
    }
    sql
}
fn write(sql: impl Into<String>, parameters: Vec<Parameter>, count: CountRule) -> Statement {
    Statement {
        sql: sql.into(),
        parameters,
        count,
    }
}
fn describe(operation: &Operation) -> Descriptor {
    use Operation::*;
    let one = CountRule::AtMost(1);
    let any = CountRule::Any;
    match operation {
        ReadSettled { feed } => statement(r#"SELECT 1::bigint AS "1" FROM n_feed WHERE feed_id=$1 AND dispatch_until=0"#,vec![text(feed)],one),
        ReadPreparationWait { feed } => statement(r#"SELECT processing_next_at,processing_until FROM n_observation WHERE feed_id=$1 AND state='staging' AND valid_eof=1 AND processing_failures<10 ORDER BY scan_started_at DESC LIMIT 1"#,vec![text(feed)],one),
        ClaimScan { checkpoint:c,lease,now } => {
            let mut values=vec![text(&c.feed),integer(*now),integer(c.generation),integer(c.epoch),integer(c.eligibility),text(lease)];
            let poll=c.poll.as_ref().map(|p|format!(" AND {}",super::polling::fence(p,&mut values))).unwrap_or_default();
            statement(format!("UPDATE n_feed AS s SET lease_id=$6,lease_until=$2+180 WHERE s.feed_id=$1 AND s.observation_generation=$3 AND EXISTS(SELECT 1 FROM n_feed f WHERE f.feed_id=s.feed_id AND f.epoch=$4 AND f.eligibility_generation=$5 AND (s.lease_id IS NULL OR s.lease_until<=$2) AND EXISTS(SELECT 1 FROM n_control WHERE name='feed_observation' AND enabled=1) AND f.admission_paused=0 AND f.no_interest_since IS NULL AND NOT EXISTS(SELECT 1 FROM n_observation o WHERE o.feed_id=f.feed_id AND o.owner_epoch=f.epoch AND ((o.state='published' AND o.drain_complete=0) OR (o.state='staging' AND o.valid_eof=1 AND o.processing_failures<10 AND o.lease_id=s.lease_id AND o.eligibility_generation=f.eligibility_generation AND o.scan_started_at>$2-604800))) AND EXISTS(SELECT 1 FROM n_interest j JOIN n_install i ON i.install_id=j.install_id WHERE j.feed_id=f.feed_id AND j.enabled=1 AND i.enabled=1)){poll}"),values,one)
        }
        ReadPriorStart { feed,since } => statement("SELECT MIN(scan_started_at) AS started FROM n_observation WHERE feed_id=$1 AND recovery_evidence=1 AND state IN('staging','abandoned') AND scan_started_at>=$2",vec![text(feed),integer(*since)],CountRule::Exactly(1)),
        Materialize { staging:s } => Descriptor { statements:vec![
            write("INSERT INTO n_snapshot(object_key,feed_id,owner_epoch,lease_id,sha256,bytes,state,created_at,gc_after) VALUES($1,$2,$3,$4,'',0,'reserved',$5,$5+604800)",vec![text(&s.snapshot),text(&s.feed),integer(s.epoch),text(&s.lease),integer(s.started_at)],CountRule::Exactly(1)),
            write("INSERT INTO n_observation(observation_id,feed_id,generation,owner_epoch,lease_id,expected_generation,snapshot_key,scan_started_at,candidate_count,eligibility_generation,state) VALUES($1,$2,$3,$4,$5,$3-1,$6,$7,0,$8,'staging')",vec![text(&s.observation),text(&s.feed),integer(s.generation),integer(s.epoch),text(&s.lease),text(&s.snapshot),integer(s.started_at),integer(s.eligibility)],CountRule::Exactly(1)),
        ] },
        ReadObject { key } => statement("SELECT sha256,bytes FROM n_snapshot WHERE object_key=$1 AND state IN('uploaded','referenced')",vec![text(key)],one),
        ReservePages { scan,keys,started_at,now } => {
            let mut values=vec![texts(keys.iter().cloned()),text(&scan.checkpoint.feed),integer(scan.checkpoint.epoch),Parameter::Text(scan.lease.clone()),integer(*started_at)];let guard=fence(scan,*now,&mut values);
            statement(format!("INSERT INTO n_snapshot(object_key,feed_id,owner_epoch,lease_id,sha256,bytes,state,created_at,gc_after) SELECT k.key,$2,$3,$4,'',0,'reserved',$5,$5+604800 FROM unnest($1::text[]) WITH ORDINALITY k(key,ordinal) WHERE {guard} ORDER BY k.ordinal"),values,any)
        }
        UploadPages { scan,pages,now } => {
            let mut values=vec![texts(pages.iter().map(|p|p.key.clone())),texts(pages.iter().map(|p|p.sha256.clone())),integers(pages.iter().map(|p|p.bytes)),texts(pages.iter().map(|p|p.index.clone())),Parameter::Text(scan.lease.clone())];let guard=fence(scan,*now,&mut values);
            statement(format!("UPDATE n_snapshot s SET sha256=j.sha256,bytes=j.bytes,gc_after=s.created_at+CASE WHEN j.index IN('identity','fingerprint') THEN 86400 ELSE 604800 END,state='uploaded' FROM unnest($1::text[],$2::text[],$3::bigint[],$4::text[]) WITH ORDINALITY j(key,sha256,bytes,index,ordinal) WHERE s.object_key=j.key AND s.state='reserved' AND s.lease_id=$5 AND {guard}"),values,any)
        }
        ReleaseUnused { keys,lease } => statement("DELETE FROM n_snapshot WHERE object_key=ANY($1::text[]) AND state='reserved' AND sha256='' AND lease_id=$2",vec![texts(keys.iter().cloned()),text(lease)],any),
        ReserveManifest { scan,manifest:m,pages,now } => {
            let mut first=vec![text(&m.key),text(&m.sha256),integer(m.bytes),integer(pages.len() as i64)]; let first_guard=fence(scan,*now,&mut first);
            let mut second=vec![text(&m.key),texts(pages.iter().map(|p|p.key.clone()))];let second_guard=fence(scan,*now,&mut second);
            Descriptor { statements:vec![
                write(format!("UPDATE n_snapshot SET sha256=$2,bytes=$3,expected_pages=$4 WHERE object_key=$1 AND state='reserved' AND {first_guard}"),first,one),
                write(format!("INSERT INTO n_snapshot_ref(manifest_key,page_key) SELECT $1,k.key FROM unnest($2::text[]) WITH ORDINALITY k(key,ordinal) WHERE {second_guard} ORDER BY k.ordinal ON CONFLICT DO NOTHING"),second,any),
            ] }
        }
        MarkManifestUploaded { scan,key,now } => {
            let mut values=vec![text(key)];let guard=fence(scan,*now,&mut values);
            statement(format!("UPDATE n_snapshot SET state='uploaded' WHERE object_key=$1 AND state IN('reserved','uploaded') AND {guard}"),values,one)
        }
        Publish { publication:p,now } => publish(p,*now),
        ReadFence { scan,now } => {let mut values=vec![];let guard=fence(scan,*now,&mut values);statement(format!("SELECT 1 AS \"1\" WHERE {guard}"),values,one)}
        Checkpoint { scan,observation,key,now } => {
            let mut values=vec![text(observation),text(key)];let guard=fence(scan,*now,&mut values);
            statement(format!("UPDATE n_observation SET preparation_key=$2,valid_eof=1,processing_token=NULL,processing_until=NULL,processing_failures=0,processing_next_at=0 WHERE observation_id=$1 AND {guard}"),values,one)
        }
        ClaimPreparation { feed,token,poll,now } => {
            let mut values=vec![text(feed),text(token),integer(*now)];let poll=poll.as_ref().map(|p|format!(" AND {}",super::polling::fence(p,&mut values))).unwrap_or_default();
            statement(format!("UPDATE n_observation SET processing_token=$2,processing_until=$3+180 WHERE feed_id=$1 AND state='staging' AND valid_eof=1 AND preparation_key IS NOT NULL AND processing_failures<10 AND processing_next_at<=$3 AND scan_started_at>$3-604800 AND (processing_token IS NULL OR processing_until<=$3) AND EXISTS(SELECT 1 FROM n_feed s JOIN n_feed f ON f.feed_id=s.feed_id WHERE s.feed_id=n_observation.feed_id AND s.lease_id=n_observation.lease_id AND s.observation_generation=n_observation.expected_generation AND f.epoch=n_observation.owner_epoch AND f.eligibility_generation=n_observation.eligibility_generation AND f.no_interest_since IS NULL AND f.admission_paused=0) AND EXISTS(SELECT 1 FROM n_control WHERE name='feed_observation' AND enabled=1){poll}"),values,any)
        }
        ReadPreparation { feed,token } => statement("SELECT o.* FROM n_observation o WHERE o.feed_id=$1 AND o.processing_token=$2",vec![text(feed),text(token)],any),
        ExtendPreparationLease { feed,lease,token,now } => statement("UPDATE n_feed SET lease_until=$3+180 WHERE feed_id=$1 AND lease_id=$2 AND EXISTS(SELECT 1 FROM n_observation WHERE processing_token=$4 AND feed_id=$1)",vec![text(feed),text(lease),integer(*now),text(token)],one),
        ReadPendingFuture { feed,cursor } => statement("SELECT episode_id,fingerprint FROM n_episode_release WHERE feed_id=$1 AND state='pending_future' AND episode_id>$2 ORDER BY episode_id LIMIT 1000",vec![text(feed),text(cursor)],CountRule::AtMost(1000)),
        PreparationFailed { observation,token,now } => statement("UPDATE n_observation SET processing_failures=processing_failures+1,processing_next_at=$3+300,processing_token=NULL,processing_until=NULL WHERE observation_id=$1 AND processing_token=$2",vec![text(observation),Parameter::Text(token.clone()),integer(*now)],one),
    }
}
fn published(feed: &str, token: &str, values: &mut Vec<Parameter>) -> String {
    let start = values.len() + 1;
    values.extend([text(feed), text(token)]);
    format!(
        "EXISTS(SELECT 1 FROM n_feed WHERE feed_id=${start} AND publish_token=${})",
        start + 1
    )
}
fn publish(p: &crate::database::slice_b::Publication, now: i64) -> Descriptor {
    let one = CountRule::AtMost(1);
    let any = CountRule::Any;
    let mut args = vec![
        text(&p.manifest),
        integer(p.generation),
        text(&p.token),
        Parameter::Text(p.etag.clone()),
        Parameter::Text(p.modified.clone()),
        integer(now),
        text(&p.scan.checkpoint.feed),
        texts(p.pages.iter().map(|v| v.key.clone())),
        Parameter::Text(p.bound_digest.clone()),
        Parameter::Text(p.validator_url.clone()),
        texts(p.pages.iter().map(|v| v.sha256.clone())),
        integers(p.pages.iter().map(|v| v.bytes)),
    ];
    let guard = fence(&p.scan, now, &mut args);
    let valid="EXISTS(SELECT 1 FROM n_snapshot s WHERE s.object_key=$1 AND s.state='uploaded' AND s.expected_pages=(SELECT COUNT(*) FROM n_snapshot_ref r WHERE r.manifest_key=s.object_key) AND NOT EXISTS(SELECT 1 FROM n_snapshot_ref r JOIN n_snapshot p ON p.object_key=r.page_key WHERE r.manifest_key=s.object_key AND (p.state NOT IN('uploaded','referenced') OR p.sha256='' OR p.bytes=0)) AND NOT EXISTS(SELECT 1 FROM unnest($8::text[],$11::text[],$12::bigint[]) WITH ORDINALITY j(key,sha256,bytes,ordinal) WHERE NOT EXISTS(SELECT 1 FROM n_snapshot_ref r JOIN n_snapshot p ON p.object_key=r.page_key WHERE r.manifest_key=s.object_key AND p.object_key=j.key AND p.sha256=j.sha256 AND p.bytes=j.bytes)))";
    let mut statements=vec![write(format!("UPDATE n_feed SET observation_generation=$2,snapshot_key=$1,publish_token=$3,etag=$4,last_modified=$5,validator_url=$10,validator_at=$6,last_success_at=$6,semantic_digest=$9,lease_id=NULL,lease_until=NULL WHERE feed_id=$7 AND {guard} AND {valid}"),args,one)];
    let feed = &p.scan.checkpoint.feed;
    let mut args = vec![
        text(&p.observation),
        integer(now),
        integer(p.candidate_count),
        text(&p.counts_json),
        text(&p.metadata_json),
        Parameter::Text(p.etag.clone()),
        Parameter::Text(p.modified.clone()),
    ];
    let token = published(feed, &p.token, &mut args);
    statements.push(write(format!("UPDATE n_observation SET state='published',valid_eof=1,preparation_key=NULL,processing_token=NULL,processing_until=NULL,completed_at=$2,candidate_count=$3,spooled_count=$3,candidate_storage='r2',reason_counts_json=$4,metadata_json=$5,etag=$6,last_modified=$7,drain_complete=CASE WHEN $3=0 THEN 1 ELSE 0 END WHERE observation_id=$1 AND {token}"),args,one));
    let mut args = vec![text(&p.manifest)];
    let token = published(feed, &p.token, &mut args);
    statements.push(write(format!("UPDATE n_snapshot SET state='referenced' WHERE (object_key=$1 OR object_key IN(SELECT page_key FROM n_snapshot_ref WHERE manifest_key=$1)) AND {token}"),args,any));
    let mut args = vec![
        text(feed),
        Parameter::Integer(p.credible_release_at),
        integer(p.undated),
        integer(p.started_at),
        Parameter::Integer(p.credible_cadence),
        Parameter::Integer(p.publish_cadence),
    ];
    let schedule = if let Some(due) = p.due_at {
        args.extend([
            integer(due),
            integer(now),
            integer(i64::from(p.candidate_count == 0)),
        ]);
        ",due_at=$7,retry_at=0,poll_failures=0,handling_failures=0,baseline_at=COALESCE(baseline_at,$8),last_poll_at=$8,last_poll_outcome='published',last_poll_error=NULL,dispatch_until=CASE WHEN $9<>0 THEN 0 ELSE dispatch_until END"
    } else {
        ""
    };
    let token = published(feed, &p.token, &mut args);
    statements.push(write(format!("UPDATE n_feed SET credible_release_at=GREATEST(COALESCE(credible_release_at,0),COALESCE($2,0),CASE WHEN $3>0 THEN $4 ELSE 0 END),credible_cadence=COALESCE($5,credible_cadence),publish_cadence=COALESCE($6,publish_cadence){schedule} WHERE feed_id=$1 AND {token}"),args,one));
    let mut args = vec![text(feed), integer(p.generation), integer(p.started_at)];
    let token = published(feed, &p.token, &mut args);
    statements.push(write(format!("UPDATE n_interest SET absence_generation=COALESCE(absence_generation,$2),absence_at=COALESCE(absence_at,$3) WHERE feed_id=$1 AND enabled=1 AND activated_at<=$3 AND {token}"),args,any));
    let mut args = vec![text(feed), integer(p.started_at)];
    let token = published(feed, &p.token, &mut args);
    statements.push(write(format!("UPDATE n_observation SET recovery_evidence=0 WHERE feed_id=$1 AND scan_started_at<=$2 AND {token}"),args,any));
    if !p.withdrawn.is_empty() {
        let mut args = vec![text(feed), texts(p.withdrawn.iter().cloned())];
        let token = published(feed, &p.token, &mut args);
        statements.push(write(format!("UPDATE n_episode_release SET state='withdrawn',disposition='withdrawn' WHERE feed_id=$1 AND state='pending_future' AND episode_id=ANY($2::text[]) AND {token}"),args,any));
    }
    Descriptor { statements }
}
