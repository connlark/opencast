//! R2 reservations and D1 publication are separate durability boundaries.
//! This type has storage capabilities only, never an APNs or event binding.
use super::snapshot::{checksum, Manifest, Page};
use crate::delivery::{
    db::*,
    wire::{int, string},
};
use serde_json::{json, Value};
use worker::{Bucket, D1Database, Error, Result};

pub fn fault(code: &str) -> Error {
    Error::RustError(code.into())
}

/// What a scan read before it fetched: the authority and published checkpoint
/// its failure evidence is recorded against. It outlives the `Store`, which a
/// finishing or cancelled scan consumes.
#[derive(Clone, Debug)]
pub struct Bound {
    feed_id: String,
    started_at: i64,
    epoch: i64,
    eligibility: i64,
    /// Published generation and the success token read with it. Every settle
    /// and publication replaces the token, so an unchanged pair proves that no
    /// scan has succeeded since this one read its checkpoint. Integer seconds
    /// cannot order two executions; the token can.
    generation: i64,
    token: Option<String>,
}
impl Bound {
    /// A scan reached the publisher but not a published snapshot. Its start
    /// conservatively bounds the first observation of whatever a retry finds,
    /// so a retry can shorten, never renew, an alert's deadline. Only the
    /// earliest start matters, so one row per failure streak is kept; a matched
    /// 304, an unchanged 200 or a publication retires it.
    ///
    /// The insert is fenced on what this scan read. A success committed since,
    /// by a duplicate or a newer generation, proved absence after this scan
    /// began: a bound written then would date the next release into the past.
    /// A new owner epoch or eligibility revision is another authority's
    /// history. The row is the inert shape a failed scan always left: staging,
    /// never a valid EOF, so nothing can resume or publish it.
    pub async fn record(&self, db: &D1Database) -> Result<()> {
        let (table, generation, _) = Store::names();
        let (key, lease) = (id(), id());
        let absent = "NOT EXISTS(SELECT 1 FROM n_observation o WHERE o.feed_id=f.feed_id AND o.recovery_evidence=1 AND o.state IN('staging','abandoned') AND o.scan_started_at>=?2-604800 AND o.scan_started_at<=?2)";
        let inserted = "EXISTS(SELECT 1 FROM n_snapshot WHERE object_key=?3 AND lease_id=?4)";
        db.batch(vec![
            statement(db,&format!("INSERT INTO n_snapshot(object_key,feed_id,owner_epoch,lease_id,sha256,bytes,state,created_at,gc_after) SELECT ?3,f.feed_id,f.epoch,?4,'',0,'reserved',?2,?2+604800 FROM n_feed f LEFT JOIN {table} s ON s.feed_id=f.feed_id WHERE f.feed_id=?1 AND f.epoch=?5 AND f.eligibility_generation=?6 AND COALESCE(s.{generation},0)=?7 AND s.publish_token IS ?8 AND {absent}"),&[json!(self.feed_id),json!(self.started_at),json!(key),json!(lease),json!(self.epoch),json!(self.eligibility),json!(self.generation),json!(self.token)])?,
            statement(db,&format!("INSERT INTO n_observation(observation_id,feed_id,generation,owner_epoch,lease_id,expected_generation,snapshot_key,scan_started_at,candidate_count,eligibility_generation,state) SELECT ?5,f.feed_id,COALESCE(s.{generation},0)+1,f.epoch,?4,COALESCE(s.{generation},0),?3,?2,0,f.eligibility_generation,'staging' FROM n_feed f LEFT JOIN {table} s ON s.feed_id=f.feed_id WHERE f.feed_id=?1 AND {inserted}"),&[json!(self.feed_id),json!(self.started_at),json!(key),json!(lease),json!(id())])?,
        ]).await?;
        Ok(())
    }
}

pub struct Store {
    pub db: D1Database,
    pub bucket: Bucket,
    pub feed_id: String,
    pub observation_id: String,
    pub lease: String,
    pub epoch: i64,
    pub eligibility: i64,
    pub generation: i64,
    pub started_at: i64,
    pub first_observed_at: i64,
    pub manifest_key: String,
    pub previous: Option<Manifest>,
    pub previous_key: Option<String>,
    pub processing_token: Option<String>,
    pub poll: Option<crate::polling::Fence>,
    /// Digest of the published scan's exact membership, bound to its snapshot.
    pub digest: Option<String>,
    /// The published checkpoint's success token, read with the authority.
    token: Option<String>,
    /// A publisher request was sent. Before that a scan has seen nothing, so
    /// its cancellation, deferral or failure bounds nothing.
    reached: bool,
    /// A deferred store has read authority only: no lease, row or object.
    materialized: bool,
    reserved: Vec<String>,
    reservation_batch_size: usize,
    uploaded: Vec<Page>,
}
impl Store {
    fn names() -> (&'static str, &'static str, &'static str) {
        ("n_feed", "observation_generation", "feed_observation")
    }
    /// Same admission predicate for the read-only start and the later claim.
    /// `s` is the checkpoint row; the queued owner carries its checkpoint.
    fn admissible() -> &'static str {
        "(s.lease_id IS NULL OR s.lease_until<=?2) AND EXISTS(SELECT 1 FROM n_control WHERE name=?3 AND enabled=1) AND f.admission_paused=0 AND f.no_interest_since IS NULL AND NOT EXISTS(SELECT 1 FROM n_observation o WHERE o.feed_id=f.feed_id AND o.owner_epoch=f.epoch AND ((o.state='published' AND o.drain_complete=0) OR (o.state='staging' AND o.valid_eof=1 AND o.processing_failures<10 AND o.lease_id=s.lease_id AND o.eligibility_generation=f.eligibility_generation AND o.scan_started_at>?2-604800))) AND EXISTS(SELECT 1 FROM n_interest j JOIN n_install i ON i.install_id=j.install_id WHERE j.feed_id=f.feed_id AND j.enabled=1 AND i.enabled=1)"
    }
    /// Read authority and the published checkpoint without writing. A 304 or a
    /// semantically unchanged 200 never becomes an observation, so nothing is
    /// claimed or reserved until the fetched body has proved a change.
    pub async fn deferred(
        db: D1Database,
        bucket: Bucket,
        feed_id: &str,
        poll: Option<crate::polling::Fence>,
    ) -> Result<Option<Self>> {
        let (table, generation, control_name) = Self::names();
        let t = now();
        let sql = format!("SELECT f.epoch,f.eligibility_generation,s.snapshot_key,s.semantic_digest,s.publish_token,COALESCE(s.{generation},0) AS generation FROM n_feed f LEFT JOIN {table} s ON s.feed_id=f.feed_id WHERE f.feed_id=?1 AND {}{}", Self::admissible(), poll.as_ref().map(|p| format!(" AND {}", p.sql(t))).unwrap_or_default());
        let args = [json!(feed_id), json!(t), json!(control_name)];
        let mut row = first(&db, &sql, &args).await?;
        if row.is_none() {
            // A poisoned preparation keeps its lease until abandoned.
            Self::abandon_poisoned(&db, feed_id).await?;
            row = first(&db, &sql, &args).await?;
        }
        let Some(row) = row else {
            return Ok(None);
        };
        Ok(Some(Self {
            db,
            bucket,
            feed_id: feed_id.into(),
            observation_id: id(),
            lease: id(),
            epoch: int(&row, "epoch"),
            eligibility: int(&row, "eligibility_generation"),
            generation: int(&row, "generation") + 1,
            started_at: t,
            first_observed_at: t,
            manifest_key: id(),
            processing_token: None,
            poll,
            digest: row["semantic_digest"].as_str().map(str::to_string),
            token: row["publish_token"].as_str().map(str::to_string),
            reached: false,
            materialized: false,
            previous: None,
            previous_key: row["snapshot_key"].as_str().map(str::to_string),
            reserved: vec![],
            reservation_batch_size: 4,
            uploaded: vec![],
        }))
    }
    pub fn bound(&self) -> Bound {
        Bound {
            feed_id: self.feed_id.clone(),
            started_at: self.started_at,
            epoch: self.epoch,
            eligibility: self.eligibility,
            generation: self.generation - 1,
            token: self.token.clone(),
        }
    }
    /// A publisher request is about to be sent. A Queue consumer outlives the
    /// step it may cancel, so it is handed the bound the step can no longer
    /// record itself.
    pub fn reached_publisher(&mut self) {
        self.reached = true;
        if let Some(poll) = &self.poll {
            poll.reached.replace(Some(self.bound()));
        }
    }
    /// This scan committed a settle or a publication: absence is proved and
    /// there is nothing left for its consumer to bound.
    fn succeeded(&self) {
        if let Some(poll) = &self.poll {
            poll.reached.take();
        }
    }
    /// Whether this scan's end still owes a first-observed bound. A scan that
    /// never reached the publisher saw nothing, and a claimed scan already has
    /// its own row.
    pub fn owes_bound(&self) -> bool {
        self.reached && !self.materialized
    }
    pub fn is_baseline(&self) -> bool {
        self.previous_key.is_none()
    }
    /// The digest a later scan must reproduce, bound to the snapshot it
    /// describes. Snapshot keys are never reused, unlike a generation number,
    /// which history expiry resets: a binary that publishes without maintaining
    /// the digest moves the key, so what it leaves behind can never match.
    pub fn bound_digest(snapshot_key: &str, digest: &str) -> String {
        format!("{snapshot_key}:{digest}")
    }
    pub fn unchanged_from(&self, digest: &str) -> bool {
        self.previous_key
            .as_deref()
            .is_some_and(|key| self.digest.as_deref() == Some(&Self::bound_digest(key, digest)))
    }
    /// Claim the scan lease and create the staging rows for a proved change.
    /// The scan start stays the fetch start, so date windows, absence and the
    /// conservative first-observed bound do not move to the claim time.
    pub async fn materialize(&mut self) -> Result<bool> {
        if self.materialized {
            return Ok(true);
        }
        let (table, generation, control_name) = Self::names();
        Self::abandon_poisoned(&self.db, &self.feed_id).await?;
        let t = now();
        // The checkpoint read at the start must still be the published one.
        let claim = format!("UPDATE {table} AS s SET lease_id=?7,lease_until=?2+180 WHERE s.feed_id=?1 AND s.{generation}=?4 AND EXISTS(SELECT 1 FROM n_feed f WHERE f.feed_id=s.feed_id AND f.epoch=?5 AND f.eligibility_generation=?6 AND {}){}", Self::admissible(), self.poll.as_ref().map(|p| format!(" AND {}", p.sql(t))).unwrap_or_default());
        if run(
            &self.db,
            &claim,
            &[
                json!(self.feed_id),
                json!(t),
                json!(control_name),
                json!(self.generation - 1),
                json!(self.epoch),
                json!(self.eligibility),
                json!(self.lease),
            ],
        )
        .await?
            == 0
        {
            return Ok(false);
        }
        let prior_start = first(&self.db, "SELECT MIN(scan_started_at) AS started FROM n_observation WHERE feed_id=?1 AND recovery_evidence=1 AND state IN('staging','abandoned') AND scan_started_at>=?2", &[json!(self.feed_id),json!(self.started_at-7*86400)]).await?.and_then(|v|v["started"].as_i64()).unwrap_or(self.started_at);
        self.first_observed_at = prior_start.min(self.started_at);
        self.db.batch(vec![
            statement(&self.db,"INSERT INTO n_snapshot(object_key,feed_id,owner_epoch,lease_id,sha256,bytes,state,created_at,gc_after) VALUES(?1,?2,?3,?4,'',0,'reserved',?5,?5+604800)",&[json!(self.manifest_key),json!(self.feed_id),json!(self.epoch),json!(self.lease),json!(self.started_at)])?,
            statement(&self.db,"INSERT INTO n_observation(observation_id,feed_id,generation,owner_epoch,lease_id,expected_generation,snapshot_key,scan_started_at,candidate_count,eligibility_generation,state) VALUES(?1,?2,?3,?4,?5,?3-1,?6,?7,0,?8,'staging')",&[json!(self.observation_id),json!(self.feed_id),json!(self.generation),json!(self.epoch),json!(self.lease),json!(self.manifest_key),json!(self.started_at),json!(self.eligibility)])?,
        ]).await?;
        self.materialized = true;
        Ok(true)
    }
    pub async fn load_previous(&mut self) -> Result<()> {
        if let Some(key) = &self.previous_key {
            let body = self.read_key(key).await?;
            let manifest: Manifest = serde_json::from_slice(&body)?;
            if manifest.schema_version != 1
                || manifest.feed_id != self.feed_id
                || manifest.generation != self.generation - 1
            {
                return Err(fault("snapshot_manifest_identity"));
            }
            self.previous = Some(manifest);
        }
        Ok(())
    }
    /// The same fence is used for every stage and again by publication. SQL
    /// inserts do not rely on another statement having changed a row. Before a
    /// claim there is no lease to own: the published checkpoint must be the
    /// one this scan read, with no other scan holding the feed.
    pub fn fence(&self, t: i64) -> String {
        let (table, generation, control) = Self::names();
        // IDs are generated UUID/digests; no external text is interpolated.
        let admission = " AND f.admission_paused=0";
        let lease = if self.materialized {
            format!("s.lease_id='{}' AND s.lease_until>{t}", self.lease)
        } else {
            format!("(s.lease_id IS NULL OR s.lease_until<={t})")
        };
        format!("EXISTS(SELECT 1 FROM {table} s JOIN n_feed f ON f.feed_id=s.feed_id WHERE s.feed_id='{}' AND {lease} AND s.{generation}={} AND f.epoch={} AND f.eligibility_generation={}{} AND f.no_interest_since IS NULL) AND EXISTS(SELECT 1 FROM n_control WHERE name='{control}' AND enabled=1)",self.feed_id,self.generation-1,self.epoch,self.eligibility,admission) + &self.processing_token.as_ref().map(|token|format!(" AND EXISTS(SELECT 1 FROM n_observation WHERE observation_id='{}' AND processing_token='{token}' AND processing_until>{t})",self.observation_id)).unwrap_or_default() + &self.poll.as_ref().map(|p| format!(" AND {}",p.sql(t))).unwrap_or_default()
    }
    pub async fn read_key(&self, key: &str) -> Result<Vec<u8>> {
        let row=first(&self.db,"SELECT sha256,bytes FROM n_snapshot WHERE object_key=?1 AND state IN('uploaded','referenced')",&[json!(key)]).await?.ok_or_else(||fault("snapshot_unverified"))?;
        let bytes = self
            .bucket
            .get(key)
            .execute()
            .await?
            .ok_or_else(|| fault("snapshot_missing"))?
            .body()
            .ok_or_else(|| fault("snapshot_body_missing"))?
            .bytes()
            .await?;
        if bytes.len() as i64 != int(&row, "bytes") || checksum(&bytes) != string(&row, "sha256") {
            return Err(fault("snapshot_integrity"));
        }
        Ok(bytes)
    }
    /// Page descriptors came from a verified immutable manifest. Avoid a D1
    /// lookup per read; the page body remains checked against its exact digest.
    pub async fn read(&self, page: &Page) -> Result<Vec<u8>> {
        let object = self
            .bucket
            .get(&page.key)
            .execute()
            .await?
            .ok_or_else(|| fault("snapshot_missing"))?;
        if object.size() as usize != page.bytes {
            return Err(fault("snapshot_size"));
        }
        let bytes = object
            .body()
            .ok_or_else(|| fault("snapshot_body_missing"))?
            .bytes()
            .await?;
        if bytes.len() != page.bytes || checksum(&bytes) != page.sha256 {
            return Err(fault("snapshot_integrity"));
        }
        Ok(bytes)
    }
    pub async fn put(
        &mut self,
        index: &str,
        bytes: Vec<u8>,
        count: usize,
        first_hash: String,
        last_hash: String,
    ) -> Result<Page> {
        if !self.materialized {
            // Every object is reserved under a lease before upload.
            return Err(fault("observation_unclaimed"));
        }
        if self.reserved.is_empty() {
            self.flush().await?;
            let keys: Vec<_> = (0..self.reservation_batch_size).map(|_| id()).collect();
            let sql=format!("INSERT INTO n_snapshot(object_key,feed_id,owner_epoch,lease_id,sha256,bytes,state,created_at,gc_after) SELECT value,?2,?3,?4,'',0,'reserved',?5,?5+604800 FROM json_each(?1) WHERE {}",self.fence(now()));
            if run(
                &self.db,
                &sql,
                &[
                    json!(keys),
                    json!(self.feed_id),
                    json!(self.epoch),
                    json!(self.lease),
                    json!(self.started_at),
                ],
            )
            .await?
                != keys.len()
            {
                if let Some(poll) = &self.poll {
                    poll.rejected(&self.db).await?;
                }
                return Err(fault("observation_fence"));
            }
            self.reserved = keys;
            self.reservation_batch_size = (self.reservation_batch_size * 2).min(64);
        }
        let key = self.reserved.pop().expect("reserved batch");
        let page = Page {
            key,
            sha256: checksum(&bytes),
            bytes: bytes.len(),
            count,
            first_hash,
            last_hash,
            index: index.into(),
        };
        self.upload(&page, bytes).await?;
        self.uploaded.push(page.clone());
        Ok(page)
    }
    async fn upload(&self, page: &Page, bytes: Vec<u8>) -> Result<()> {
        let created = self
            .bucket
            .put(&page.key, bytes)
            .sha256(hex::decode(&page.sha256).map_err(|_| fault("snapshot_digest"))?)
            .only_if(worker::Conditional {
                etag_does_not_match: Some("*".into()),
                ..Default::default()
            })
            .execute()
            .await?;
        if created.is_none() {
            // A lost upload response may leave the immutable key present. A
            // retry verifies it rather than overwriting its content/version.
            let existing = self
                .bucket
                .get(&page.key)
                .execute()
                .await?
                .ok_or_else(|| fault("snapshot_put_failed"))?;
            if existing.size() as usize != page.bytes {
                return Err(fault("snapshot_immutable_conflict"));
            }
            let bytes = existing
                .body()
                .ok_or_else(|| fault("snapshot_body_missing"))?
                .bytes()
                .await?;
            if checksum(&bytes) != page.sha256 {
                return Err(fault("snapshot_immutable_conflict"));
            }
        }
        let head = self
            .bucket
            .head(&page.key)
            .await?
            .ok_or_else(|| fault("snapshot_head_missing"))?;
        if head.size() as usize != page.bytes {
            return Err(fault("snapshot_head_size"));
        }
        // R2 checks the supplied SHA-256 on PUT; HEAD independently verifies size.
        Ok(())
    }
    pub async fn flush(&mut self) -> Result<()> {
        if self.uploaded.is_empty() {
            return Ok(());
        }
        let sql=format!("UPDATE n_snapshot SET sha256=json_extract(j.value,'$.sha256'),bytes=json_extract(j.value,'$.bytes'),gc_after=created_at+CASE WHEN json_extract(j.value,'$.index') IN('identity','fingerprint') THEN 86400 ELSE 604800 END,state='uploaded' FROM json_each(?1) j WHERE object_key=json_extract(j.value,'$.key') AND state='reserved' AND lease_id=?2 AND {}",self.fence(now()));
        if run(&self.db, &sql, &[json!(self.uploaded), json!(self.lease)]).await?
            != self.uploaded.len()
        {
            if let Some(poll) = &self.poll {
                poll.rejected(&self.db).await?;
            }
            return Err(fault("observation_upload_fence"));
        }
        self.uploaded.clear();
        Ok(())
    }
    async fn release_unused(&mut self) -> Result<()> {
        if !self.reserved.is_empty() {
            // Only keys still owned by this pool are safe: popped keys may
            // already exist in R2 after a lost upload response.
            run(&self.db, "DELETE FROM n_snapshot WHERE object_key IN(SELECT value FROM json_each(?1)) AND state='reserved' AND sha256='' AND lease_id=?2", &[json!(self.reserved), json!(self.lease)]).await?;
            self.reserved.clear();
        }
        Ok(())
    }

    pub async fn publish(
        &mut self,
        manifest: &Manifest,
        counts: &Value,
        metadata: &Value,
        etag: Option<&str>,
        modified: Option<&str>,
    ) -> Result<bool> {
        self.flush().await?;
        self.release_unused().await?;
        let mut pages = manifest.pages.clone();
        pages.extend(manifest.candidate_pages.clone());
        let bytes = serde_json::to_vec(manifest)?;
        let page = Page {
            key: self.manifest_key.clone(),
            sha256: checksum(&bytes),
            bytes: bytes.len(),
            count: pages.len(),
            first_hash: String::new(),
            last_hash: String::new(),
            index: "manifest".into(),
        };
        let fence = self.fence(now());
        self.db.batch(vec![
            statement(&self.db,&format!("UPDATE n_snapshot SET sha256=?2,bytes=?3,expected_pages=?4 WHERE object_key=?1 AND state='reserved' AND {fence}"),&[json!(page.key),json!(page.sha256),json!(page.bytes),json!(pages.len())])?,
            statement(&self.db,&format!("INSERT INTO n_snapshot_ref(manifest_key,page_key) SELECT ?1,json_extract(value,'$.key') FROM json_each(?2) WHERE {fence} ON CONFLICT DO NOTHING"),&[json!(page.key),json!(pages)])?,
        ]).await?;
        self.upload(&page, bytes).await?;
        if run(&self.db,&format!("UPDATE n_snapshot SET state='uploaded' WHERE object_key=?1 AND state IN('reserved','uploaded') AND {fence}"),&[json!(page.key)]).await?==0 {if let Some(poll) = &self.poll { poll.rejected(&self.db).await?; } return Ok(false);}
        let token = id();
        let t = now();
        let fence = self.fence(t);
        let (table, generation) = ("n_feed", "observation_generation");
        let published = format!(
            "EXISTS(SELECT 1 FROM {table} WHERE feed_id='{}' AND publish_token='{token}')",
            self.feed_id
        );
        let valid="EXISTS(SELECT 1 FROM n_snapshot s WHERE s.object_key=?1 AND s.state='uploaded' AND s.expected_pages=(SELECT COUNT(*) FROM n_snapshot_ref r WHERE r.manifest_key=s.object_key) AND NOT EXISTS(SELECT 1 FROM n_snapshot_ref r JOIN n_snapshot p ON p.object_key=r.page_key WHERE r.manifest_key=s.object_key AND (p.state NOT IN('uploaded','referenced') OR p.sha256='' OR p.bytes=0)) AND NOT EXISTS(SELECT 1 FROM json_each(?8) j WHERE NOT EXISTS(SELECT 1 FROM n_snapshot_ref r JOIN n_snapshot p ON p.object_key=r.page_key WHERE r.manifest_key=s.object_key AND p.object_key=json_extract(j.value,'$.key') AND p.sha256=json_extract(j.value,'$.sha256') AND p.bytes=json_extract(j.value,'$.bytes'))))";
        let mut statements=vec![
            statement(&self.db,&format!("UPDATE {table} SET {generation}=?2,snapshot_key=?1,publish_token=?3,etag=?4,last_modified=?5,last_success_at=?6,semantic_digest=?9,lease_id=NULL,lease_until=NULL WHERE feed_id=?7 AND {fence} AND {valid}"),&[json!(page.key),json!(self.generation),json!(token),json!(etag),json!(modified),json!(t),json!(self.feed_id),json!(pages),json!(metadata["semantic_digest"].as_str().map(|d| Self::bound_digest(&page.key, d)))])?,
            statement(&self.db,&format!("UPDATE n_observation SET state='published',valid_eof=1,preparation_key=NULL,processing_token=NULL,processing_until=NULL,completed_at=?2,candidate_count=?3,spooled_count=?3,candidate_storage='r2',reason_counts_json=?4,metadata_json=?5,etag=?6,last_modified=?7,drain_complete=CASE WHEN ?3=0 THEN 1 ELSE 0 END WHERE observation_id=?1 AND {published}"),&[json!(self.observation_id),json!(t),json!(manifest.candidate_count),counts.clone(),{let mut m=metadata.clone();let o=m.as_object_mut().expect("metadata");o.remove("withdrawn");o.remove("semantic_digest");m},json!(etag),json!(modified)])?,
            statement(&self.db,&format!("UPDATE n_snapshot SET state='referenced' WHERE (object_key=?1 OR object_key IN(SELECT page_key FROM n_snapshot_ref WHERE manifest_key=?1)) AND {published}"),&[json!(page.key)])?,
        ];
        {
            let undated = counts["undated"].as_i64().unwrap_or(0)
                + counts["anomalous_date"].as_i64().unwrap_or(0);
            // A Queue-driven publication settles its schedule atomically with
            // the pointer. With nothing to drain it settles the generation too.
            let settle = self.poll.as_ref().map(|poll| {
                poll.settle(
                    t,
                    "published",
                    metadata["credible_release_at"]
                        .as_i64()
                        .max((undated > 0).then_some(self.started_at)),
                    metadata["credible_cadence"].as_i64(),
                    metadata["publish_cadence"].as_i64(),
                )
            });
            let schedule = if settle.is_some() {
                ",due_at=?7,retry_at=0,poll_failures=0,handling_failures=0,baseline_at=COALESCE(baseline_at,?8),last_poll_at=?8,last_poll_outcome='published',last_poll_error=NULL,dispatch_until=CASE WHEN ?9 THEN 0 ELSE dispatch_until END"
            } else {
                ""
            };
            statements.push(statement(&self.db,&format!("UPDATE n_feed SET credible_release_at=MAX(COALESCE(credible_release_at,0),COALESCE(?2,0),CASE WHEN ?3>0 THEN ?4 ELSE 0 END),credible_cadence=COALESCE(?5,credible_cadence),publish_cadence=COALESCE(?6,publish_cadence){schedule} WHERE feed_id=?1 AND {published}"),&[vec![json!(self.feed_id),metadata["credible_release_at"].clone(),json!(undated),json!(self.started_at),metadata["credible_cadence"].clone(),metadata["publish_cadence"].clone()],settle.map(|s| vec![json!(s.due_at),json!(t),json!(manifest.candidate_count==0)]).unwrap_or_default()].concat())?);
            statements.push(statement(&self.db,&format!("UPDATE n_interest SET absence_generation=COALESCE(absence_generation,?2),absence_at=COALESCE(absence_at,?3) WHERE feed_id=?1 AND enabled=1 AND activated_at<=?3 AND {published}"),&[json!(self.feed_id),json!(self.generation),json!(self.started_at)])?);
        }
        statements.push(statement(&self.db, &format!("UPDATE n_observation SET recovery_evidence=0 WHERE feed_id=?1 AND scan_started_at<=?2 AND {published}"), &[json!(self.feed_id),json!(self.started_at)])?);
        if let Some(withdrawn) = metadata["withdrawn"].as_array() {
            for chunk in withdrawn.chunks(1000) {
                statements.push(statement(&self.db, &format!("UPDATE n_episode_release SET state='withdrawn',disposition='withdrawn' WHERE feed_id=?1 AND state='pending_future' AND episode_id IN(SELECT value FROM json_each(?2)) AND {published}"), &[json!(self.feed_id),json!(chunk)])?);
            }
        }
        let result = self.db.batch(statements).await?;
        let published = result[0].meta()?.and_then(|m| m.changes).unwrap_or(0) > 0;
        if published {
            self.succeeded();
        } else {
            if first(
                &self.db,
                &format!("SELECT 1 WHERE {}", self.fence(now())),
                &[],
            )
            .await?
            .is_some()
            {
                return Err(fault("snapshot_publication_incomplete"));
            }
            if let Some(poll) = &self.poll {
                poll.rejected(&self.db).await?;
            }
        }
        Ok(published)
    }
}

impl Store {
    /// A matched 304 or a semantically unchanged 200: one fenced batch that
    /// moves only checkpoint/schedule fields. It never creates an observation,
    /// snapshot, candidate or receipt row, and never advances the generation.
    /// `digest` is `None` for a 304, whose proof is the request validator.
    pub async fn unchanged(
        &self,
        etag: Option<&str>,
        modified: Option<&str>,
        digest: Option<&str>,
        settle: Option<&crate::polling::Settle>,
    ) -> Result<bool> {
        if self.materialized {
            return Err(fault("unchanged_after_claim"));
        }
        let (table, generation, _) = Self::names();
        let token = id();
        let t = now();
        let fence = self.fence(t);
        let bound = match (digest, self.previous_key.as_deref()) {
            (Some(digest), Some(key)) => Some(Self::bound_digest(key, digest)),
            (Some(_), None) => return Err(fault("unchanged_without_snapshot")),
            (None, _) => None,
        };
        // A 304 proves nothing unless it answers the published validator. A
        // 200 must reproduce the membership digest of the snapshot the pointer
        // still names, and then its own validators describe that snapshot.
        let (valid, validators) = if bound.is_some() {
            (
                "snapshot_key IS NOT NULL AND semantic_digest=?6 AND substr(?6,1,length(snapshot_key)+1)=snapshot_key||':'",
                ",etag=?1,last_modified=?2",
            )
        } else {
            ("snapshot_key IS NOT NULL AND ?6 IS NULL AND ((etag IS NOT NULL AND etag=?1) OR (etag IS NULL AND last_modified IS NOT NULL AND last_modified=?2))", "")
        };
        let published = format!(
            "EXISTS(SELECT 1 FROM {table} WHERE feed_id='{}' AND publish_token='{token}')",
            self.feed_id
        );
        let mut args = vec![
            json!(etag),
            json!(modified),
            json!(t),
            json!(token),
            json!(self.feed_id),
            json!(bound),
        ];
        let schedule = match settle {
            Some(settle) => {
                args.extend([
                    json!(settle.due_at),
                    json!(settle.credible_release_at),
                    json!(settle.credible_cadence),
                    json!(settle.publish_cadence),
                    json!(settle.outcome),
                ]);
                ",due_at=?7,retry_at=0,poll_failures=0,handling_failures=0,dispatch_until=0,baseline_at=COALESCE(baseline_at,?3),credible_release_at=COALESCE(?8,credible_release_at),credible_cadence=COALESCE(?9,credible_cadence),publish_cadence=COALESCE(?10,publish_cadence),last_poll_at=?3,last_poll_outcome=?11,last_poll_error=NULL"
            }
            None => "",
        };
        let mut writes=vec![
            statement(&self.db,&format!("UPDATE {table} SET last_success_at=?3,publish_token=?4{validators}{schedule} WHERE feed_id=?5 AND {valid} AND {fence}"),&args)?,
            // Complete absence evidence, exactly as a full publication. Failed
            // scans before this check cannot date later releases.
            statement(&self.db,&format!("UPDATE n_observation SET recovery_evidence=0 WHERE feed_id=?1 AND scan_started_at<=?2 AND recovery_evidence=1 AND {published}"),&[json!(self.feed_id),json!(self.started_at)])?,
        ];
        {
            // COALESCE only ever fills a missing value; skip settled rows.
            writes.push(statement(&self.db,&format!("UPDATE n_interest SET absence_generation=COALESCE(absence_generation,(SELECT {generation} FROM {table} WHERE feed_id=?1)),absence_at=COALESCE(absence_at,?2) WHERE feed_id=?1 AND enabled=1 AND activated_at<=?2 AND (absence_generation IS NULL OR absence_at IS NULL) AND {published}"),&[json!(self.feed_id),json!(self.started_at)])?);
        }
        let results = self.db.batch(writes).await?;
        let published = results[0].meta()?.and_then(|m| m.changes).unwrap_or(0) > 0;
        if published {
            self.succeeded();
        }
        if !published
            && first(
                &self.db,
                &format!("SELECT 1 WHERE {}", self.fence(now())),
                &[],
            )
            .await?
            .is_none()
        {
            if let Some(poll) = &self.poll {
                poll.rejected(&self.db).await?;
            }
        }
        Ok(published)
    }
}

impl Store {
    pub async fn checkpoint(&mut self, preparation: &super::prepare::Preparation) -> Result<()> {
        let page = self
            .put(
                "preparation",
                serde_json::to_vec(preparation)?,
                0,
                String::new(),
                String::new(),
            )
            .await?;
        self.flush().await?;
        self.release_unused().await?;
        if run(&self.db,&format!("UPDATE n_observation SET preparation_key=?2,valid_eof=1,processing_token=NULL,processing_until=NULL,processing_failures=0,processing_next_at=0 WHERE observation_id=?1 AND {}",self.fence(now())),&[json!(self.observation_id),json!(page.key)]).await?==0 {if let Some(poll) = &self.poll { poll.rejected(&self.db).await?; } return Err(fault("preparation_checkpoint_fence"));}
        Ok(())
    }
    /// Poison is terminal for this preparation, not a week-long feed lockout.
    /// Retain its original start/pages as recovery evidence for the next scan.
    pub async fn abandon_poisoned(db: &D1Database, feed_id: &str) -> Result<()> {
        let table = "n_feed";
        let results = db.batch(vec![
            statement(db, "UPDATE n_observation SET state='abandoned',completed_at=?2,processing_token=NULL,processing_until=NULL,reason_counts_json=json_set(reason_counts_json,'$.preparation_poisoned',1) WHERE observation_id IN(SELECT observation_id FROM n_observation WHERE feed_id=?1 AND state='staging' AND valid_eof=1 AND processing_failures>=10 AND (processing_token IS NULL OR processing_until<=?2) ORDER BY scan_started_at LIMIT 20)", &[json!(feed_id),json!(now())])?,
            statement(db, &format!("UPDATE {table} SET lease_id=NULL,lease_until=NULL WHERE feed_id=?1 AND lease_id IN(SELECT lease_id FROM n_observation WHERE feed_id=?1 AND state='abandoned' AND processing_failures>=10 AND json_extract(reason_counts_json,'$.preparation_poisoned')=1)"), &[json!(feed_id)])?,
        ]).await?;
        let count = results[0].meta()?.and_then(|m| m.changes).unwrap_or(0);
        if count > 0 {
            worker::console_warn!(
                "{}",
                json!({"event":"feed_preparation_abandoned","reason":"preparation_poisoned","count":count})
            );
        }
        Ok(())
    }

    pub async fn resume_fenced(
        db: D1Database,
        bucket: Bucket,
        feed_id: &str,
        poll: Option<crate::polling::Fence>,
    ) -> Result<Option<(Self, super::prepare::Preparation)>> {
        let table = "n_feed";
        let generation = "observation_generation";
        let control = "feed_observation";
        let token = id();
        let t = now();
        let admission = " AND f.admission_paused=0";
        let valid=format!("EXISTS(SELECT 1 FROM {table} s JOIN n_feed f ON f.feed_id=s.feed_id WHERE s.feed_id=n_observation.feed_id AND s.lease_id=n_observation.lease_id AND s.{generation}=n_observation.expected_generation AND f.epoch=n_observation.owner_epoch AND f.eligibility_generation=n_observation.eligibility_generation AND f.no_interest_since IS NULL{admission}) AND EXISTS(SELECT 1 FROM n_control WHERE name='{control}' AND enabled=1)");
        Self::abandon_poisoned(&db, feed_id).await?;
        let valid = valid
            + &poll
                .as_ref()
                .map(|p| format!(" AND {}", p.sql(t)))
                .unwrap_or_default();
        let changes=run(&db,&format!("UPDATE n_observation SET processing_token=?2,processing_until=?3+180 WHERE feed_id=?1 AND state='staging' AND valid_eof=1 AND preparation_key IS NOT NULL AND processing_failures<10 AND processing_next_at<=?3 AND scan_started_at>?3-604800 AND (processing_token IS NULL OR processing_until<=?3) AND {valid}"),&[json!(feed_id),json!(token),json!(t)]).await?;
        if changes == 0 {
            return Ok(None);
        }
        let row = first(
            &db,
            "SELECT o.* FROM n_observation o WHERE o.feed_id=?1 AND o.processing_token=?2",
            &[json!(feed_id), json!(token)],
        )
        .await?
        .ok_or_else(|| fault("preparation_claim_lost"))?;
        run(&db,&format!("UPDATE {table} SET lease_until=?3+180 WHERE feed_id=?1 AND lease_id=?2 AND EXISTS(SELECT 1 FROM n_observation WHERE processing_token=?4 AND feed_id=?1)"),&[json!(feed_id),row["lease_id"].clone(),json!(t),json!(token)]).await?;
        let mut store = Self {
            db,
            bucket,
            feed_id: feed_id.into(),
            observation_id: string(&row, "observation_id").into(),
            lease: string(&row, "lease_id").into(),
            epoch: int(&row, "owner_epoch"),
            eligibility: int(&row, "eligibility_generation"),
            generation: int(&row, "generation"),
            started_at: int(&row, "scan_started_at"),
            first_observed_at: int(&row, "scan_started_at"),
            manifest_key: string(&row, "snapshot_key").into(),
            previous: None,
            previous_key: None,
            processing_token: Some(token),
            poll,
            digest: None,
            token: None,
            reached: true,
            materialized: true,
            reserved: vec![],
            reservation_batch_size: 4,
            uploaded: vec![],
        };
        let preparation: super::prepare::Preparation =
            serde_json::from_slice(&store.read_key(string(&row, "preparation_key")).await?)?;
        store.first_observed_at = preparation.first_observed_at;
        Ok(Some((store, preparation)))
    }
}
