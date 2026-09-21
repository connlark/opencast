//! Fixed-width exact history. A merge holds one historical page and the bounded
//! current document's hashes; historical membership is never truncated.
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

pub type Hash = [u8; 32];
pub const HASHES_PER_PAGE: usize = 4096;
pub const PAGE_BYTES: usize = HASHES_PER_PAGE * 32;
pub const CANDIDATES_PER_PAGE: usize = 100;
pub const CANDIDATE_BYTES: usize = 64 * 1024;

pub fn identity(value: &str) -> Hash {
    Sha256::digest(value.as_bytes()).into()
}
pub fn checksum(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}
/// Exact membership of one complete document: the sorted, deduplicated identity
/// and fingerprint sets, length-prefixed so neither can borrow from the other.
/// Every observation decision is a function of these two sets against history,
/// so equal digests mean no novel identity, fingerprint or withdrawal. Item
/// order, pinning and edits outside the fingerprint do not change it; any edit
/// to a title, audio URL, summary or duration changes a fingerprint and does.
pub fn semantic_digest(identities: &[Hash], fingerprints: &[Hash]) -> String {
    debug_assert!(identities.windows(2).all(|w| w[0] < w[1]));
    debug_assert!(fingerprints.windows(2).all(|w| w[0] < w[1]));
    let mut digest = Sha256::new();
    digest.update(b"opencast-semantic-membership-v1");
    for set in [identities, fingerprints] {
        digest.update((set.len() as u64).to_be_bytes());
        for hash in set {
            digest.update(hash);
        }
    }
    hex::encode(digest.finalize())
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Page {
    pub key: String,
    pub sha256: String,
    pub bytes: usize,
    pub count: usize,
    pub first_hash: String,
    pub last_hash: String,
    pub index: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub schema_version: u32,
    pub feed_id: String,
    pub generation: i64,
    pub pages: Vec<Page>,
    pub candidate_pages: Vec<Page>,
    pub candidate_count: usize,
}

pub fn decode(page: &Page, bytes: &[u8]) -> Result<Vec<Hash>, &'static str> {
    if page.count == 0
        || page.count > HASHES_PER_PAGE
        || bytes.len() != page.count * 32
        || page.bytes != bytes.len()
        || checksum(bytes) != page.sha256
    {
        return Err("snapshot_integrity");
    }
    let hashes = bytes.as_chunks::<32>().0.to_vec();
    if hashes.windows(2).any(|w| w[0] >= w[1])
        || hex::encode(hashes[0]) != page.first_hash
        || hex::encode(hashes[hashes.len() - 1]) != page.last_hash
    {
        return Err("snapshot_order");
    }
    Ok(hashes)
}

/// Consume one sorted old page, producing exact union chunks of at most 4096.
/// `current` is sorted/unique and bounded by the supported current RSS size.
/// The caller streams old pages in order and flushes the tail with `finish`.
#[derive(Default, Debug, Clone, Serialize, Deserialize)]
pub struct MergeState {
    pub position: usize,
    pub tail: Vec<Hash>,
    pub last_old: Option<Hash>,
}
pub struct Merge<'a> {
    current: &'a [Hash],
    position: usize,
    pub novel: Vec<Hash>,
    tail: Vec<Hash>,
    last_old: Option<Hash>,
}
impl<'a> Merge<'a> {
    pub fn new(current: &'a [Hash]) -> Self {
        Self {
            current,
            position: 0,
            novel: Vec::new(),
            tail: Vec::with_capacity(HASHES_PER_PAGE),
            last_old: None,
        }
    }
    pub fn resume(current: &'a [Hash], state: MergeState) -> Self {
        Self {
            current,
            position: state.position,
            tail: state.tail,
            last_old: state.last_old,
            novel: vec![],
        }
    }
    pub fn state(&self) -> MergeState {
        MergeState {
            position: self.position,
            tail: self.tail.clone(),
            last_old: self.last_old,
        }
    }
    pub fn page(&mut self, old: &[Hash]) -> Result<Vec<Vec<Hash>>, &'static str> {
        let mut output = Vec::new();
        for &hash in old {
            if self.last_old.is_some_and(|last| last >= hash) {
                return Err("snapshot_page_order");
            }
            self.last_old = Some(hash);
            while self.position < self.current.len() && self.current[self.position] < hash {
                let value = self.current[self.position];
                self.novel.push(value);
                self.push(value, &mut output);
                self.position += 1;
            }
            if self.current.get(self.position) == Some(&hash) {
                self.position += 1;
            }
            self.push(hash, &mut output);
        }
        Ok(output)
    }
    pub fn finish(&mut self) -> Vec<Vec<Hash>> {
        let mut output = Vec::new();
        while self.position < self.current.len() {
            let value = self.current[self.position];
            self.novel.push(value);
            self.push(value, &mut output);
            self.position += 1;
        }
        if !self.tail.is_empty() {
            output.push(std::mem::take(&mut self.tail));
        }
        output
    }
    fn push(&mut self, hash: Hash, output: &mut Vec<Vec<Hash>>) {
        self.tail.push(hash);
        if self.tail.len() == HASHES_PER_PAGE {
            output.push(std::mem::replace(
                &mut self.tail,
                Vec::with_capacity(HASHES_PER_PAGE),
            ));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn sorted(values: &[&str]) -> Vec<Hash> {
        let mut hashes: Vec<_> = values.iter().map(|v| identity(v)).collect();
        hashes.sort_unstable();
        hashes.dedup();
        hashes
    }
    #[test]
    fn semantic_digest_is_exact_membership_not_document_order() {
        let ids = sorted(&["a", "b", "c"]);
        let fps = sorted(&["fa", "fb", "fc"]);
        let base = semantic_digest(&ids, &fps);
        // Reordered, pinned or duplicated items are the same two sets.
        assert_eq!(base, semantic_digest(&sorted(&["c", "a", "b", "a"]), &fps));
        // A bonus release, a removal and an edited fingerprint each differ.
        assert_ne!(
            base,
            semantic_digest(&sorted(&["a", "b", "c", "bonus"]), &fps)
        );
        assert_ne!(base, semantic_digest(&sorted(&["a", "b"]), &fps));
        assert_ne!(
            base,
            semantic_digest(&ids, &sorted(&["fa", "fb", "edited"]))
        );
        // Length prefixes keep a hash from moving between the two sets.
        let moved = semantic_digest(&sorted(&["a", "b"]), &sorted(&["c"]));
        assert_ne!(
            moved,
            semantic_digest(&sorted(&["a"]), &sorted(&["b", "c"]))
        );
        assert_ne!(semantic_digest(&[], &[]), semantic_digest(&ids, &[]));
    }
    #[test]
    fn growing_exact_history_across_pages_retains_removed_identities() {
        let mut old: Vec<_> = (0..100_000).map(|i| identity(&i.to_string())).collect();
        old.sort_unstable();
        old.dedup();
        let mut current: Vec<_> = (99_900..100_100)
            .map(|i| identity(&i.to_string()))
            .collect();
        current.sort_unstable();
        let mut merge = Merge::new(&current);
        let mut union = Vec::new();
        for page in old.chunks(HASHES_PER_PAGE) {
            union.extend(merge.page(page).unwrap());
        }
        union.extend(merge.finish());
        assert!(union.iter().all(|p| p.len() <= HASHES_PER_PAGE));
        let union: Vec<_> = union.into_iter().flatten().collect();
        assert_eq!(union.len(), 100_100);
        assert_eq!(merge.novel.len(), 100);
        assert!(union.windows(2).all(|w| w[0] < w[1]));
        assert!(old.iter().all(|h| union.binary_search(h).is_ok()));
    }
    #[test]
    fn page_integrity_and_order_are_verified() {
        let bytes = vec![1; 32];
        let mut page = Page {
            key: "opaque".into(),
            sha256: checksum(&bytes),
            bytes: 32,
            count: 1,
            first_hash: hex::encode(&bytes),
            last_hash: hex::encode(&bytes),
            index: "identity".into(),
        };
        assert!(decode(&page, &bytes).is_ok());
        page.last_hash = "wrong".into();
        assert!(decode(&page, &bytes).is_err());
        assert!(decode(&page, &[2; 32]).is_err());
    }
}
