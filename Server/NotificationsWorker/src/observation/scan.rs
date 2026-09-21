use super::{
    policy::Reason,
    snapshot::{self, Hash, Manifest, Page, CANDIDATES_PER_PAGE, CANDIDATE_BYTES},
    store::{fault, Store},
};
use crate::{
    feed_identity,
    rss::{self, scan::EpisodeSink, ParsedEpisode, RSSParseError},
};
use base64::{engine::general_purpose::STANDARD_NO_PAD, Engine};
use serde::{Deserialize, Serialize};
use serde_json::json;
use worker::Result;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Candidate {
    pub ordinal: usize,
    pub episode_id: String,
    pub fingerprint: Option<String>,
    pub title: String,
    pub summary: Option<String>,
    pub artwork: Option<String>,
    pub duration: Option<i64>,
    pub raw_date: Option<String>,
    pub published_at: Option<i64>,
    pub first_observed_at: i64,
    pub eligible_at: i64,
    pub reason: Reason,
}
// Private pre-classification spool omits repeated field names and observation-
// wide timestamps. Published candidate pages retain the explicit v1 object form.
pub(super) type SpoolRecord = (
    usize,
    String,
    Option<String>,
    String,
    Option<String>,
    Option<String>,
    Option<i64>,
    Option<String>,
    Option<i64>,
);
pub(super) fn from_spool(record: SpoolRecord, first_observed_at: i64) -> Result<Candidate> {
    let (
        ordinal,
        episode_id,
        fingerprint,
        title,
        summary,
        artwork,
        duration,
        raw_date,
        published_at,
    ) = record;
    Ok(Candidate {
        ordinal,
        episode_id: expand_hash(&episode_id)?,
        fingerprint: fingerprint.as_deref().map(expand_hash).transpose()?,
        title,
        summary,
        artwork,
        duration,
        raw_date,
        published_at,
        first_observed_at,
        eligible_at: first_observed_at,
        reason: Reason::Undated,
    })
}
fn compact_hash(hash: &str) -> String {
    STANDARD_NO_PAD.encode(hex::decode(hash).expect("derived hash"))
}
fn expand_hash(value: &str) -> Result<String> {
    let bytes = STANDARD_NO_PAD
        .decode(value)
        .map_err(|_| fault("spool_hash"))?;
    if bytes.len() != 32 {
        return Err(fault("spool_hash"));
    }
    Ok(hex::encode(bytes))
}
impl Candidate {
    fn from_episode(episode: &ParsedEpisode, raw_date: Option<&str>, at: i64) -> Self {
        Self {
            ordinal: 0,
            episode_id: episode.id.clone(),
            fingerprint: feed_identity::episode_notification_fingerprint(
                feed_identity::EpisodeNotificationFingerprintInput {
                    title: &episode.title,
                    guid: episode.guid.as_deref(),
                    audio_url: episode.audio_url.as_deref(),
                    duration_seconds: episode.duration_seconds,
                    summary: episode.summary.as_deref(),
                    show_notes_html: episode.show_notes_html.as_deref(),
                    episode_id: &episode.id,
                },
            ),
            title: bounded(&episode.title, 512),
            summary: episode
                .summary
                .as_deref()
                .map(|s| bounded(s, 512))
                .filter(|s| !s.is_empty()),
            artwork: episode
                .artwork_url
                .as_deref()
                .map(|s| bounded(s, 512))
                .filter(|s| !s.is_empty()),
            duration: episode.duration_seconds.filter(|n| (0..=86400).contains(n)),
            raw_date: raw_date.map(|s| bounded(s, 128)),
            published_at: episode.published_at,
            first_observed_at: at,
            eligible_at: at,
            reason: Reason::Undated,
        }
    }
    pub(super) fn order(&self) -> (i64, &str) {
        (self.eligible_at, &self.episode_id)
    }
}
pub fn bounded(s: &str, limit: usize) -> String {
    let mut result = String::new();
    for c in s.chars().filter(|c| !c.is_control()) {
        if result.len() + c.len_utf8() > limit {
            break;
        }
        result.push(c);
    }
    result.trim().to_string()
}

/// How a complete, valid-EOF scan ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Finished {
    /// The published membership was reproduced. `true` when the fenced
    /// checkpoint/schedule commit applied; nothing else was written.
    Unchanged(bool),
    /// Another scan owns the feed; this one created nothing.
    Unclaimed,
    /// A change is durable and its preparation continues in later steps.
    Staged,
    /// A quiet baseline published, or lost its fence, in this step.
    Published(bool),
}

pub struct Observer {
    pub store: Store,
    pending: super::scratch::Pending,
    identities: Vec<Hash>,
    fingerprints: Vec<Hash>,
    item_keys: Vec<u8>,
    buffer: Vec<Candidate>,
    buffer_bytes: usize,
    credible_dates: Vec<i64>,
}
impl Observer {
    pub fn new(store: Store) -> Self {
        Self {
            store,
            pending: Default::default(),
            identities: vec![],
            fingerprints: vec![],
            item_keys: vec![],
            buffer: vec![],
            buffer_bytes: 2,
            credible_dates: vec![],
        }
    }
    async fn push(&mut self, episode: &ParsedEpisode, raw: Option<&str>) -> Result<()> {
        if let Some(date) = episode
            .published_at
            .filter(|d| *d <= self.store.started_at + 600)
        {
            if !self.credible_dates.contains(&date) {
                self.credible_dates.push(date.min(self.store.started_at));
                self.credible_dates.sort_unstable_by(|a, b| b.cmp(a));
                self.credible_dates.truncate(10);
            }
        }
        let mut candidate = Candidate::from_episode(episode, raw, self.store.first_observed_at);
        candidate.ordinal = self.identities.len();
        if self.identities.len() == self.identities.capacity() {
            self.identities.reserve_exact(snapshot::HASHES_PER_PAGE);
        }
        self.identities.push(snapshot::identity(&episode.id));
        if let Some(fingerprint) = &candidate.fingerprint {
            if self.fingerprints.len() == self.fingerprints.capacity() {
                self.fingerprints.reserve_exact(snapshot::HASHES_PER_PAGE);
            }
            self.fingerprints.push(
                hex::decode(fingerprint)
                    .map_err(|_| fault("fingerprint_hash"))?
                    .try_into()
                    .map_err(|_| fault("fingerprint_hash"))?,
            );
        }
        // A quiet baseline needs only fixed-width hashes, never item metadata.
        if self.store.is_baseline() {
            return Ok(());
        }
        if self.item_keys.capacity() - self.item_keys.len() < 65 {
            self.item_keys.reserve_exact(65 * 2000);
        }
        self.item_keys
            .extend(hex::decode(&episode.id).map_err(|_| fault("episode_hash"))?);
        self.item_keys
            .push(u8::from(candidate.fingerprint.is_some()));
        self.item_keys.extend(
            candidate
                .fingerprint
                .as_ref()
                .map(|h| hex::decode(h).expect("fingerprint hash"))
                .unwrap_or_else(|| vec![0; 32]),
        );
        let size = serde_json::to_vec(&candidate)?.len() + 1;
        if self.buffer.len() == CANDIDATES_PER_PAGE || self.buffer_bytes + size > CANDIDATE_BYTES {
            self.flush_spool().await?;
        }
        self.buffer_bytes += size;
        self.buffer.push(candidate);
        Ok(())
    }
    async fn flush_spool(&mut self) -> Result<()> {
        if self.buffer.is_empty() {
            return Ok(());
        }
        let records: Vec<_> = self
            .buffer
            .iter()
            .map(|c| {
                (
                    c.ordinal,
                    compact_hash(&c.episode_id),
                    c.fingerprint.as_deref().map(compact_hash),
                    &c.title,
                    &c.summary,
                    &c.artwork,
                    c.duration,
                    &c.raw_date,
                    c.published_at,
                )
            })
            .collect();
        // No change is proved yet, so this page is not an object or a row.
        self.pending
            .push(
                &self.store.bucket,
                &self.store.feed_id,
                serde_json::to_vec(&records)?,
                records.len(),
            )
            .await?;
        self.buffer.clear();
        self.buffer_bytes = 2;
        Ok(())
    }
    /// The scan was deferred, failed, truncated or lost its deadline. It
    /// publishes nothing and keeps no scratch. Whether its start survives as a
    /// bound is its sink's decision, which outlives this observer.
    pub async fn discard(&mut self) {
        self.pending.discard().await;
    }
    pub async fn finish(
        mut self,
        parsed: &rss::scan::ScannedFeed,
        feed_url: &str,
        etag: Option<&str>,
        modified: Option<&str>,
    ) -> Result<Finished> {
        self.flush_spool().await?;
        self.identities.sort_unstable();
        self.identities.dedup();
        self.fingerprints.sort_unstable();
        self.fingerprints.dedup();
        let digest = snapshot::semantic_digest(&self.identities, &self.fingerprints);
        let mut dates = self.credible_dates.clone();
        let publish_cadence = crate::poll_scheduling::publish_cadence_seconds(&mut dates);
        let credible_cadence = crate::polling::policy::cadence(&self.credible_dates);
        if self.store.unchanged_from(&digest) {
            // Exact membership equals the published scan: no identity or
            // fingerprint is novel and no pending future has left the document.
            self.pending.discard().await;
            let settle = self.store.poll.as_ref().map(|poll| {
                poll.settle(
                    crate::delivery::db::now(),
                    "unchanged",
                    self.credible_dates.first().copied(),
                    credible_cadence,
                    publish_cadence,
                )
            });
            return Ok(Finished::Unchanged(
                self.store
                    .unchanged(etag, modified, Some(&digest), settle.as_ref())
                    .await?,
            ));
        }
        if !self.store.materialize().await? {
            self.pending.discard().await;
            return Ok(Finished::Unclaimed);
        }
        self.store.load_previous().await?;
        let spool = std::mem::take(&mut self.pending)
            .materialize(&mut self.store)
            .await?;
        let mut identities = vec![];
        let mut fingerprints = vec![];
        for chunk in self.identities.chunks(snapshot::HASHES_PER_PAGE) {
            identities.push(put_hashes(&mut self.store, "identity", chunk.to_vec()).await?);
        }
        for chunk in self.fingerprints.chunks(snapshot::HASHES_PER_PAGE) {
            fingerprints.push(put_hashes(&mut self.store, "fingerprint", chunk.to_vec()).await?);
        }
        let identity_count = self.identities.len();
        // The exact current hashes are now durable; release their scan buffers
        // before serializing the remaining item keys and preparation manifest.
        drop(std::mem::take(&mut self.identities));
        drop(std::mem::take(&mut self.fingerprints));
        let metadata = json!({"feed_url":feed_url,"podcast_title":bounded(&parsed.title,512),"artwork_url":parsed.artwork_url.as_deref().map(|s|bounded(s,512)),"credible_release_at":self.credible_dates.first(),"credible_cadence":credible_cadence,"publish_cadence":publish_cadence,"semantic_digest":digest});
        if let Some(previous) = self.store.previous.take() {
            let mut keys = vec![];
            for chunk in self.item_keys.chunks(65 * 2000) {
                keys.push(
                    self.store
                        .put(
                            "item_keys",
                            chunk.to_vec(),
                            chunk.len() / 65,
                            String::new(),
                            String::new(),
                        )
                        .await?,
                );
            }
            let preparation = super::prepare::Preparation::new(
                previous,
                identities,
                fingerprints,
                keys,
                spool,
                metadata,
                etag,
                modified,
                self.store.first_observed_at,
            );
            self.store.checkpoint(&preparation).await?;
            return Ok(Finished::Staged);
        }
        let mut pages = identities;
        pages.extend(fingerprints);
        let manifest = Manifest {
            schema_version: 1,
            feed_id: self.store.feed_id.clone(),
            generation: self.store.generation,
            pages,
            candidate_pages: vec![],
            candidate_count: 0,
        };
        self.store
            .publish(
                &manifest,
                &json!({"baseline":identity_count}),
                &metadata,
                etag,
                modified,
            )
            .await
            .map(Finished::Published)
    }
}
impl EpisodeSink for Observer {
    async fn item(
        &mut self,
        episode: &ParsedEpisode,
        raw_date: Option<&str>,
    ) -> std::result::Result<(), RSSParseError> {
        self.push(episode, raw_date)
            .await
            .map_err(|_| RSSParseError::ResourceLimit("observation_stage_failed"))
    }
}
pub(super) async fn put_hashes(store: &mut Store, index: &str, hashes: Vec<Hash>) -> Result<Page> {
    let first = hex::encode(hashes[0]);
    let last = hex::encode(hashes[hashes.len() - 1]);
    let count = hashes.len();
    let bytes = hashes.into_iter().flatten().collect();
    store.put(index, bytes, count, first, last).await
}
pub(super) async fn put_candidates(
    store: &mut Store,
    index: &str,
    candidates: &[Candidate],
) -> Result<Page> {
    let bytes = serde_json::to_vec(candidates)?;
    if candidates.len() > CANDIDATES_PER_PAGE || bytes.len() > CANDIDATE_BYTES {
        return Err(fault("candidate_page_limit"));
    }
    store
        .put(index, bytes, candidates.len(), String::new(), String::new())
        .await
}
