//! R2 reservations and database publication are separate durability boundaries.
//! This type has storage capabilities only, never an APNs or event binding.
use super::snapshot::{checksum, Manifest, Page};
use crate::database::{
    self,
    observations::{Checkpoint, Processing, Reservation, Unchanged},
    polling::Operation,
    slice_b::{self, Operation as BOperation, Page as StoragePage, Publication, Scan, Staging},
};
use crate::delivery::{
    db::*,
    wire::{int, string},
};
use serde_json::{json, Value};
use worker::{Bucket, Error, Result};

pub fn fault(code: &str) -> Error {
    Error::RustError(code.into())
}

/// What a scan read before it fetched: the authority and published checkpoint
/// its failure evidence is recorded against. It outlives the `Store`, which a
/// finishing or cancelled scan consumes.
pub use crate::database::observations::Bound;
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
    pub async fn record(&self, db: &crate::database::Authority) -> Result<()> {
        database::execute(
            db,
            Operation::RecordFailedScan {
                bound: self.clone(),
                reservation: Reservation {
                    snapshot: id(),
                    lease: id(),
                    observation: id(),
                },
            },
        )
        .await?;
        Ok(())
    }
}

pub struct Store {
    pub db: crate::database::Authority,
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
    /// Read authority and the published checkpoint without writing. A 304 or a
    /// semantically unchanged 200 never becomes an observation, so nothing is
    /// claimed or reserved until the fetched body has proved a change.
    pub async fn deferred(
        db: crate::database::Authority,
        bucket: Bucket,
        feed_id: &str,
        poll: Option<crate::polling::Fence>,
    ) -> Result<Option<Self>> {
        let t = now();
        let request = Operation::ReadScanCheckpoint {
            feed: feed_id.into(),
            poll: poll.as_ref().map(|p| p.storage()),
            now: t,
        };
        let mut row = database::execute(&db, request.clone()).await?.first();
        if row.is_none() {
            // Poison abandonment belongs to the later preparation slice. Keep
            // this storage fallback and its second read as separate source boundaries.
            Self::abandon_poisoned(&db, feed_id).await?;
            row = database::execute(&db, request).await?.first();
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
    /// The published digest describes the snapshot the pointer still names.
    /// A missing or stale one can never prove a body unchanged, so its feed
    /// keeps parsing until a 200 repairs it.
    pub fn has_bound_digest(&self) -> bool {
        self.previous_key.as_deref().is_some_and(|key| {
            self.digest
                .as_deref()
                .and_then(|digest| digest.strip_prefix(key))
                .is_some_and(|rest| rest.starts_with(':'))
        })
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
        Self::abandon_poisoned(&self.db, &self.feed_id).await?;
        let t = now();
        // Preserve the claim, recovery-bound read, and two-insert boundaries.
        if let Some(poll) = &self.poll {
            *poll.scan_lease.borrow_mut() = Some(self.lease.clone());
        }
        if slice_b::execute(
            &self.db,
            BOperation::ClaimScan {
                checkpoint: self.storage_checkpoint(),
                lease: self.lease.clone(),
                now: t,
            },
        )
        .await?
        .count()
            == 0
        {
            return Ok(false);
        }
        let prior_start = slice_b::execute(
            &self.db,
            BOperation::ReadPriorStart {
                feed: self.feed_id.clone(),
                since: self.started_at - 7 * 86400,
            },
        )
        .await?
        .first()
        .and_then(|v| v["started"].as_i64())
        .unwrap_or(self.started_at);
        self.first_observed_at = prior_start.min(self.started_at);
        slice_b::execute(
            &self.db,
            BOperation::Materialize {
                staging: Staging {
                    feed: self.feed_id.clone(),
                    epoch: self.epoch,
                    eligibility: self.eligibility,
                    generation: self.generation,
                    lease: self.lease.clone(),
                    observation: self.observation_id.clone(),
                    snapshot: self.manifest_key.clone(),
                    started_at: self.started_at,
                },
            },
        )
        .await?;
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
    fn storage_scan(&self) -> Scan {
        Scan {
            checkpoint: self.storage_checkpoint(),
            lease: self.materialized.then(|| self.lease.clone()),
        }
    }
    fn storage_page(page: &Page) -> StoragePage {
        StoragePage {
            key: page.key.clone(),
            sha256: page.sha256.clone(),
            bytes: page.bytes as i64,
            index: page.index.clone(),
            count: page.count as i64,
            first_hash: page.first_hash.clone(),
            last_hash: page.last_hash.clone(),
        }
    }
    pub async fn read_key(&self, key: &str) -> Result<Vec<u8>> {
        let row = slice_b::execute(&self.db, BOperation::ReadObject { key: key.into() })
            .await?
            .first()
            .ok_or_else(|| fault("snapshot_unverified"))?;
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
    /// Page descriptors came from a verified immutable manifest. Avoid a database
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
            if slice_b::execute(
                &self.db,
                BOperation::ReservePages {
                    scan: self.storage_scan(),
                    keys: keys.clone(),
                    started_at: self.started_at,
                    now: now(),
                },
            )
            .await?
            .count()
                != keys.len() as u64
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
        if slice_b::execute(
            &self.db,
            BOperation::UploadPages {
                scan: self.storage_scan(),
                pages: self.uploaded.iter().map(Self::storage_page).collect(),
                now: now(),
            },
        )
        .await?
        .count()
            != self.uploaded.len() as u64
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
            slice_b::execute(
                &self.db,
                BOperation::ReleaseUnused {
                    keys: self.reserved.clone(),
                    lease: self.lease.clone(),
                },
            )
            .await?;
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
        validator_url: Option<&str>,
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
        let reserve_time = now();
        let storage_pages: Vec<_> = pages.iter().map(Self::storage_page).collect();
        slice_b::execute(
            &self.db,
            BOperation::ReserveManifest {
                scan: self.storage_scan(),
                manifest: Self::storage_page(&page),
                pages: storage_pages.clone(),
                now: reserve_time,
            },
        )
        .await?;
        self.upload(&page, bytes).await?;
        // The original post-upload statement uses the reservation's fence time.
        if slice_b::execute(
            &self.db,
            BOperation::MarkManifestUploaded {
                scan: self.storage_scan(),
                key: page.key.clone(),
                now: reserve_time,
            },
        )
        .await?
        .count()
            == 0
        {
            if let Some(poll) = &self.poll {
                poll.rejected(&self.db).await?;
            }
            return Ok(false);
        }
        let token = id();
        let t = now();
        let undated = counts["undated"].as_i64().unwrap_or(0)
            + counts["anomalous_date"].as_i64().unwrap_or(0);
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
        let mut stored_metadata = metadata.clone();
        let object = stored_metadata.as_object_mut().expect("metadata");
        object.remove("withdrawn");
        object.remove("semantic_digest");
        let publication = Publication {
            scan: self.storage_scan(),
            observation: self.observation_id.clone(),
            manifest: page.key.clone(),
            pages: storage_pages,
            generation: self.generation,
            token,
            started_at: self.started_at,
            candidate_count: manifest.candidate_count as i64,
            counts_json: serde_json::to_string(counts)?,
            metadata_json: serde_json::to_string(&stored_metadata)?,
            bound_digest: metadata["semantic_digest"]
                .as_str()
                .map(|d| Self::bound_digest(&page.key, d)),
            etag: etag.map(str::to_owned),
            modified: modified.map(str::to_owned),
            validator_url: validator_url.map(str::to_owned),
            credible_release_at: metadata["credible_release_at"].as_i64(),
            credible_cadence: metadata["credible_cadence"].as_i64(),
            publish_cadence: metadata["publish_cadence"].as_i64(),
            undated,
            due_at: settle.map(|s| s.due_at),
            withdrawn: metadata["withdrawn"]
                .as_array()
                .map(|values| {
                    values
                        .iter()
                        .map(|v| v.as_str().expect("withdrawn episode ID").to_owned())
                        .collect()
                })
                .unwrap_or_default(),
        };
        let published = slice_b::execute(
            &self.db,
            BOperation::Publish {
                publication,
                now: t,
            },
        )
        .await?
        .count()
            > 0;
        if published {
            self.succeeded();
        } else {
            if slice_b::execute(
                &self.db,
                BOperation::ReadFence {
                    scan: self.storage_scan(),
                    now: now(),
                },
            )
            .await?
            .first()
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
    fn storage_checkpoint(&self) -> Checkpoint {
        Checkpoint {
            feed: self.feed_id.clone(),
            epoch: self.epoch,
            eligibility: self.eligibility,
            generation: self.generation - 1,
            processing: self.processing_token.as_ref().map(|token| Processing {
                observation: self.observation_id.clone(),
                token: token.clone(),
            }),
            poll: self.poll.as_ref().map(|poll| poll.storage()),
        }
    }
}

impl Store {
    /// A matched 304 or a semantically unchanged 200: one fenced batch that
    /// moves only checkpoint/schedule fields. It never creates an observation,
    /// snapshot, candidate or receipt row, and never advances the generation.
    /// `digest` is `None` for a 304, whose proof is the request validator.
    /// `url` is the hop that answered a parsed 200; a 304 passes `None`.
    pub async fn unchanged(
        &self,
        etag: Option<&str>,
        modified: Option<&str>,
        url: Option<&str>,
        digest: Option<&str>,
        settle: Option<&crate::polling::Settle>,
    ) -> Result<bool> {
        if self.materialized {
            return Err(fault("unchanged_after_claim"));
        }
        let token = id();
        let t = now();
        let bound = match (digest, self.previous_key.as_deref()) {
            (Some(digest), Some(key)) => Some(Self::bound_digest(key, digest)),
            (Some(_), None) => return Err(fault("unchanged_without_snapshot")),
            (None, _) => None,
        };
        let proof = Unchanged {
            checkpoint: self.storage_checkpoint(),
            started_at: self.started_at,
            token,
            etag: etag.map(str::to_owned),
            modified: modified.map(str::to_owned),
            url: url.map(str::to_owned),
            bound_digest: bound,
            schedule: settle.map(Into::into),
        };
        let published = database::execute(&self.db, Operation::SettleUnchanged { proof, now: t })
            .await?
            .count()
            > 0;
        if published {
            self.succeeded();
        }
        if !published
            && database::execute(
                &self.db,
                Operation::ReadUnchangedFence {
                    checkpoint: self.storage_checkpoint(),
                    now: now(),
                },
            )
            .await?
            .first()
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
        if slice_b::execute(
            &self.db,
            BOperation::Checkpoint {
                scan: self.storage_scan(),
                observation: self.observation_id.clone(),
                key: page.key,
                now: now(),
            },
        )
        .await?
        .count()
            == 0
        {
            if let Some(poll) = &self.poll {
                poll.rejected(&self.db).await?;
            }
            return Err(fault("preparation_checkpoint_fence"));
        }
        Ok(())
    }
    /// Poison is terminal for this preparation, not a week-long feed lockout.
    /// Retain its original start/pages as recovery evidence for the next scan.
    pub async fn abandon_poisoned(db: &crate::database::Authority, feed_id: &str) -> Result<()> {
        let count = crate::database::slice_e::execute(
            db,
            crate::database::slice_e::Operation::AbandonPoisoned {
                feed: feed_id.into(),
                now: now(),
            },
        )
        .await?
        .count();
        if count > 0 {
            worker::console_warn!(
                "{}",
                json!({"event":"feed_preparation_abandoned","reason":"preparation_poisoned","count":count})
            );
        }
        Ok(())
    }

    pub async fn resume_fenced(
        db: crate::database::Authority,
        bucket: Bucket,
        feed_id: &str,
        poll: Option<crate::polling::Fence>,
    ) -> Result<Option<(Self, super::prepare::Preparation)>> {
        let token = id();
        let t = now();
        Self::abandon_poisoned(&db, feed_id).await?;
        let changes = slice_b::execute(
            &db,
            BOperation::ClaimPreparation {
                feed: feed_id.into(),
                token: token.clone(),
                poll: poll.as_ref().map(|p| p.storage()),
                now: t,
            },
        )
        .await?
        .count();
        if changes == 0 {
            return Ok(None);
        }
        let row = slice_b::execute(
            &db,
            BOperation::ReadPreparation {
                feed: feed_id.into(),
                token: token.clone(),
            },
        )
        .await?
        .first()
        .ok_or_else(|| fault("preparation_claim_lost"))?;
        slice_b::execute(
            &db,
            BOperation::ExtendPreparationLease {
                feed: feed_id.into(),
                lease: string(&row, "lease_id").into(),
                token: token.clone(),
                now: t,
            },
        )
        .await?;
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
