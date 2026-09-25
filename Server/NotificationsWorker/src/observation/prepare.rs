//! Resumable sorted preparation. Each step reads bounded historical/spool pages
//! or writes at most 16 merge pages, then commits a new immutable checkpoint.
use super::{
    policy::classify,
    scan::{put_candidates, put_hashes, Candidate},
    snapshot::{
        self, Hash, Manifest, Merge, MergeState, Page, CANDIDATES_PER_PAGE, CANDIDATE_BYTES,
        HASHES_PER_PAGE,
    },
    store::{fault, Store},
};
use crate::delivery::{db::*, wire::string};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use worker::{Bucket, D1Database, Result};

#[derive(Serialize, Deserialize, Default)]
struct History {
    old_cursor: usize,
    merge: MergeState,
}
#[derive(Serialize, Deserialize, Default, Clone)]
struct Position {
    page: usize,
    item: usize,
}
#[derive(Serialize, Deserialize, Default)]
struct MergeJob {
    group: usize,
    positions: Vec<Position>,
    output: Vec<Page>,
    next: Vec<Vec<Page>>,
}
#[derive(Serialize, Deserialize)]
pub struct Preparation {
    previous: Manifest,
    current_ids: Vec<Page>,
    current_fingerprints: Vec<Page>,
    item_keys: Vec<Page>,
    spool: Vec<Page>,
    metadata: Value,
    etag: Option<String>,
    modified: Option<String>,
    pub first_observed_at: i64,
    phase: u8,
    history: History,
    pages: Vec<Page>,
    novel_ids: Vec<Page>,
    novel_fingerprints: Vec<Page>,
    spool_cursor: usize,
    counts: BTreeMap<String, usize>,
    candidate_count: usize,
    runs: Vec<Vec<Page>>,
    merge: MergeJob,
}
impl Preparation {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        previous: Manifest,
        current_ids: Vec<Page>,
        current_fingerprints: Vec<Page>,
        item_keys: Vec<Page>,
        spool: Vec<Page>,
        metadata: Value,
        etag: Option<&str>,
        modified: Option<&str>,
        first_observed_at: i64,
    ) -> Self {
        Self {
            previous,
            current_ids,
            current_fingerprints,
            item_keys,
            spool,
            metadata,
            etag: etag.map(str::to_string),
            modified: modified.map(str::to_string),
            first_observed_at,
            phase: 0,
            history: History::default(),
            pages: vec![],
            novel_ids: vec![],
            novel_fingerprints: vec![],
            spool_cursor: 0,
            counts: BTreeMap::new(),
            candidate_count: 0,
            runs: vec![],
            merge: MergeJob::default(),
        }
    }
    async fn history(&mut self, store: &mut Store) -> Result<()> {
        let index = if self.phase == 0 {
            "identity"
        } else {
            "fingerprint"
        };
        let current = load_hashes(
            store,
            if self.phase == 0 {
                &self.current_ids
            } else {
                &self.current_fingerprints
            },
        )
        .await?;
        let old: Vec<_> = self
            .previous
            .pages
            .iter()
            .filter(|p| p.index == index)
            .collect();
        let mut merge = Merge::resume(&current, std::mem::take(&mut self.history.merge));
        let end = (self.history.old_cursor + 32).min(old.len());
        for page in &old[self.history.old_cursor..end] {
            let hashes = snapshot::decode(page, &store.read(page).await?).map_err(fault)?;
            for output in merge.page(&hashes).map_err(fault)? {
                self.pages.push(put_hashes(store, index, output).await?);
            }
        }
        self.history.old_cursor = end;
        if end == old.len() {
            for output in merge.finish() {
                self.pages.push(put_hashes(store, index, output).await?);
            }
        }
        let novel = if self.phase == 0 {
            &mut self.novel_ids
        } else {
            &mut self.novel_fingerprints
        };
        for chunk in merge.novel.chunks(HASHES_PER_PAGE) {
            novel.push(put_hashes(store, index, chunk.to_vec()).await?);
        }
        self.history.merge = merge.state();
        if end == old.len() {
            self.history = History::default();
            self.phase += 1;
        }
        Ok(())
    }
    async fn classify(&mut self, store: &mut Store) -> Result<()> {
        let novel_ids = load_hashes(store, &self.novel_ids).await?;
        let novel_fingerprints = load_hashes(store, &self.novel_fingerprints).await?;
        if novel_ids.is_empty() && novel_fingerprints.is_empty() {
            self.counts.insert(
                "known_identity".into(),
                self.current_ids.iter().map(|p| p.count).sum(),
            );
            self.phase = 3;
            return Ok(());
        }
        // Only fixed-width keys for the supported current document are retained.
        // Known identities win aliases even when their metadata changed today.
        let mut winners = BTreeMap::<Hash, (bool, Hash)>::new();
        let mut first_ordinal = BTreeMap::<Hash, usize>::new();
        let mut ordinal = 0;
        for page in &self.item_keys {
            let bytes = store.read(page).await?;
            if bytes.len() != page.count * 65 {
                return Err(fault("item_key_size"));
            }
            for key in bytes.as_chunks::<65>().0 {
                let id: Hash = key[..32].try_into().expect("key");
                first_ordinal.entry(id).or_insert(ordinal);
                ordinal += 1;
                if key[32] == 1 {
                    let fp: Hash = key[33..].try_into().expect("fingerprint");
                    let value = (
                        novel_ids
                            .binary_search(&snapshot::identity(&hex::encode(id)))
                            .is_ok(),
                        id,
                    );
                    winners
                        .entry(fp)
                        .and_modify(|old| *old = (*old).min(value))
                        .or_insert(value);
                }
            }
        }
        let end = (self.spool_cursor + 16).min(self.spool.len());
        let mut eligible = vec![];
        for page in &self.spool[self.spool_cursor..end] {
            let records: Vec<super::scan::SpoolRecord> =
                serde_json::from_slice(&store.read(page).await?)?;
            for record in records {
                let mut c = super::scan::from_spool(record, self.first_observed_at)?;
                let raw_id: Hash = hex::decode(&c.episode_id)
                    .map_err(|_| fault("episode_hash"))?
                    .try_into()
                    .map_err(|_| fault("episode_hash"))?;
                if first_ordinal.get(&raw_id) != Some(&c.ordinal) {
                    continue;
                }
                let known_id = novel_ids
                    .binary_search(&snapshot::identity(&c.episode_id))
                    .is_err();
                let historical_fp = c.fingerprint.as_ref().is_some_and(|fp| {
                    let h: Hash = hex::decode(fp)
                        .expect("derived hash")
                        .try_into()
                        .expect("sha256");
                    novel_fingerprints.binary_search(&h).is_err()
                });
                let known_fp = historical_fp
                    || c.fingerprint.as_ref().is_some_and(|fp| {
                        let h: Hash = hex::decode(fp)
                            .expect("derived hash")
                            .try_into()
                            .expect("sha256");
                        winners.get(&h) != Some(&(true, raw_id))
                    });
                let decision = classify(
                    false,
                    known_id,
                    known_fp,
                    c.published_at,
                    c.first_observed_at,
                    store.started_at,
                );
                let reason = if known_id && !historical_fp && c.fingerprint.is_some() {
                    "metadata_only".to_string()
                } else {
                    serde_json::to_value(decision.reason)?
                        .as_str()
                        .expect("reason")
                        .into()
                };
                *self.counts.entry(reason).or_default() += 1;
                if !decision.reason.candidate() {
                    continue;
                }
                c.reason = decision.reason;
                c.eligible_at = decision.eligible_at;
                c.published_at = decision.published_at;
                eligible.push(c);
                self.candidate_count += 1;
            }
        }
        if !eligible.is_empty() {
            eligible.sort_by(|a, b| a.order().cmp(&b.order()));
            self.runs.push(write_candidates(store, &eligible).await?);
        }
        self.spool_cursor = end;
        if end == self.spool.len() {
            self.phase = 3;
        }
        Ok(())
    }
    async fn merge(&mut self, store: &mut Store) -> Result<()> {
        if self.runs.len() <= 1 {
            self.phase = 4;
            return Ok(());
        }
        let end = (self.merge.group + 8).min(self.runs.len());
        let inputs = &self.runs[self.merge.group..end];
        if self.merge.positions.is_empty() {
            self.merge.positions = vec![Position::default(); inputs.len()];
        }
        let mut readers: Vec<_> = inputs
            .iter()
            .zip(&self.merge.positions)
            .map(|(pages, p)| Reader {
                pages,
                position: p.clone(),
                buffer: vec![],
            })
            .collect();
        let mut buffer = vec![];
        let mut bytes = 2;
        let mut written = 0;
        let mut complete = false;
        loop {
            for reader in &mut readers {
                reader.fill(store).await?;
            }
            let next = readers
                .iter()
                .enumerate()
                .filter_map(|(i, r)| r.current().map(|c| (i, c)))
                .min_by(|a, b| a.1.order().cmp(&b.1.order()))
                .map(|(i, _)| i);
            let Some(next) = next else {
                complete = true;
                break;
            };
            let size = serde_json::to_vec(readers[next].current().expect("head"))?.len() + 1;
            if buffer.len() == CANDIDATES_PER_PAGE || bytes + size > CANDIDATE_BYTES {
                self.merge
                    .output
                    .push(put_candidates(store, "candidate", &buffer).await?);
                buffer.clear();
                bytes = 2;
                written += 1;
                if written == 16 {
                    break;
                }
            }
            bytes += size;
            buffer.push(readers[next].current().expect("head").clone());
            readers[next].advance();
        }
        if !buffer.is_empty() {
            self.merge
                .output
                .push(put_candidates(store, "candidate", &buffer).await?);
        }
        self.merge.positions = readers.iter().map(|r| r.position.clone()).collect();
        if complete {
            self.merge.next.push(std::mem::take(&mut self.merge.output));
            self.merge.positions.clear();
            self.merge.group = end;
            if end == self.runs.len() {
                self.runs = std::mem::take(&mut self.merge.next);
                self.merge = MergeJob::default();
            }
        }
        Ok(())
    }
    async fn publish(&mut self, store: &mut Store) -> Result<bool> {
        let identities = load_hashes(store, &self.current_ids).await?;
        let fingerprints = load_hashes(store, &self.current_fingerprints).await?;
        let mut withdrawn = vec![];
        let mut cursor = String::new();
        loop {
            let pending=rows(&store.db,"SELECT episode_id,fingerprint FROM n_episode_release WHERE feed_id=?1 AND state='pending_future' AND episode_id>?2 ORDER BY episode_id LIMIT 1000",&[json!(store.feed_id),json!(cursor)]).await?;
            for row in &pending {
                let id = string(row, "episode_id");
                let visible = row["fingerprint"]
                    .as_str()
                    .and_then(|fp| hex::decode(fp).ok())
                    .and_then(|h| Hash::try_from(h).ok())
                    .is_some_and(|h| fingerprints.binary_search(&h).is_ok());
                if identities.binary_search(&snapshot::identity(id)).is_err() && !visible {
                    withdrawn.push(id.to_string());
                }
            }
            if pending.len() < 1000 {
                break;
            }
            cursor = string(pending.last().expect("page"), "episode_id").into();
        }
        let manifest = Manifest {
            schema_version: 1,
            feed_id: store.feed_id.clone(),
            generation: store.generation,
            pages: self.pages.clone(),
            candidate_pages: self.runs.first().cloned().unwrap_or_default(),
            candidate_count: self.candidate_count,
        };
        if manifest
            .candidate_pages
            .iter()
            .map(|p| p.count)
            .sum::<usize>()
            != self.candidate_count
        {
            return Err(fault("candidate_manifest_count"));
        }
        let mut metadata = self.metadata.clone();
        metadata["withdrawn"] = json!(withdrawn);
        store
            .publish(
                &manifest,
                &json!(self.counts),
                &metadata,
                self.etag.as_deref(),
                self.modified.as_deref(),
            )
            .await
    }
}
struct Reader<'a> {
    pages: &'a [Page],
    position: Position,
    buffer: Vec<Candidate>,
}
impl Reader<'_> {
    async fn fill(&mut self, store: &Store) -> Result<()> {
        if self.buffer.is_empty() && self.position.page < self.pages.len() {
            self.buffer =
                serde_json::from_slice(&store.read(&self.pages[self.position.page]).await?)?;
        }
        Ok(())
    }
    fn current(&self) -> Option<&Candidate> {
        self.buffer.get(self.position.item)
    }
    fn advance(&mut self) {
        self.position.item += 1;
        if self.position.item == self.buffer.len() {
            self.buffer.clear();
            self.position.page += 1;
            self.position.item = 0;
        }
    }
}
async fn load_hashes(store: &Store, pages: &[Page]) -> Result<Vec<Hash>> {
    let mut hashes = Vec::new();
    for page in pages {
        hashes.extend(snapshot::decode(page, &store.read(page).await?).map_err(fault)?);
    }
    if hashes.windows(2).any(|w| w[0] >= w[1]) {
        return Err(fault("snapshot_page_order"));
    }
    Ok(hashes)
}
async fn write_candidates(store: &mut Store, candidates: &[Candidate]) -> Result<Vec<Page>> {
    let mut pages = vec![];
    let mut start = 0;
    let mut bytes = 2;
    for (i, candidate) in candidates.iter().enumerate() {
        let size = serde_json::to_vec(candidate)?.len() + 1;
        if i - start == CANDIDATES_PER_PAGE || bytes + size > CANDIDATE_BYTES {
            pages.push(put_candidates(store, "candidate", &candidates[start..i]).await?);
            start = i;
            bytes = 2;
        }
        bytes += size;
    }
    if start < candidates.len() {
        pages.push(put_candidates(store, "candidate", &candidates[start..]).await?);
    }
    Ok(pages)
}
pub async fn step_fenced(
    db: D1Database,
    bucket: Bucket,
    feed_id: &str,
    poll: Option<crate::polling::Fence>,
) -> Result<Option<bool>> {
    let Some((mut store, mut preparation)) =
        Store::resume_fenced(db, bucket, feed_id, poll).await?
    else {
        return Ok(None);
    };
    let result = async {
        match preparation.phase {
            0 | 1 => preparation.history(&mut store).await?,
            2 => preparation.classify(&mut store).await?,
            3 => preparation.merge(&mut store).await?,
            4 => return preparation.publish(&mut store).await.map(Some),
            _ => return Err(fault("preparation_phase")),
        }
        store.checkpoint(&preparation).await?;
        Ok(Some(false))
    }
    .await;
    if result.is_err() {
        run(&store.db,"UPDATE n_observation SET processing_failures=processing_failures+1,processing_next_at=?3+300,processing_token=NULL,processing_until=NULL WHERE observation_id=?1 AND processing_token=?2",&[json!(store.observation_id),json!(store.processing_token),json!(now())]).await?;
        Store::abandon_poisoned(&store.db, &store.feed_id).await?;
    }
    result
}
