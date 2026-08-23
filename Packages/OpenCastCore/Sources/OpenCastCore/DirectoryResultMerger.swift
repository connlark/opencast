import Foundation

/// Pure merge of Apple and Podcast Index search results. Apple order is
/// preserved and Apple display metadata wins; Podcast Index fills
/// missing fields, contributes feed candidates, and appends unmatched
/// results after all Apple results. Merging happens only on strong
/// identity — Apple ID, then podcast GUID, then canonical feed URL —
/// never on title, author, artwork, or fuzzy similarity.
public enum DirectoryResultMerger {
    public static func merge(
        appleResults: [DirectoryPodcastResult],
        podcastIndexResults: [DirectoryPodcastResult]
    ) -> [DirectoryPodcastResult] {
        var consumed = Set<Int>()
        var merged: [DirectoryPodcastResult] = []
        merged.reserveCapacity(appleResults.count + podcastIndexResults.count)

        for apple in appleResults {
            if let index = matchIndex(for: apple, in: podcastIndexResults, excluding: consumed) {
                consumed.insert(index)
                merged.append(mergedResult(apple: apple, podcastIndex: podcastIndexResults[index]))
            } else {
                merged.append(apple)
            }
        }

        for (index, result) in podcastIndexResults.enumerated() where !consumed.contains(index) {
            merged.append(result)
        }

        return merged
    }

    private static func matchIndex(
        for apple: DirectoryPodcastResult,
        in candidates: [DirectoryPodcastResult],
        excluding consumed: Set<Int>
    ) -> Int? {
        if let appleID = apple.appleID {
            if let index = candidates.indices.first(where: { index in
                !consumed.contains(index) && candidates[index].appleID == appleID
            }) {
                return index
            }
        }

        if let guid = normalizedGUID(apple.podcastGUID) {
            if let index = candidates.indices.first(where: { index in
                !consumed.contains(index) && normalizedGUID(candidates[index].podcastGUID) == guid
            }) {
                return index
            }
        }

        let appleFeedURLs = canonicalFeedURLStrings(of: apple)
        guard !appleFeedURLs.isEmpty else {
            return nil
        }
        return candidates.indices.first { index in
            !consumed.contains(index)
                && !canonicalFeedURLStrings(of: candidates[index]).isDisjoint(with: appleFeedURLs)
        }
    }

    private static func mergedResult(
        apple: DirectoryPodcastResult,
        podcastIndex: DirectoryPodcastResult
    ) -> DirectoryPodcastResult {
        DirectoryPodcastResult(
            id: apple.id,
            title: apple.title,
            artistName: apple.artistName ?? podcastIndex.artistName,
            feedURL: apple.feedURL ?? podcastIndex.feedURL,
            artworkURL: apple.artworkURL ?? podcastIndex.artworkURL,
            collectionViewURL: apple.collectionViewURL ?? podcastIndex.collectionViewURL,
            appleID: apple.appleID ?? podcastIndex.appleID,
            podcastIndexID: apple.podcastIndexID ?? podcastIndex.podcastIndexID,
            podcastGUID: apple.podcastGUID ?? podcastIndex.podcastGUID,
            sources: uniqueSources(apple.sources + podcastIndex.sources),
            feedCandidates: mergedCandidates(apple.feedCandidates + podcastIndex.feedCandidates)
        )
    }

    static func uniqueSources(_ sources: [PodcastDirectorySource]) -> [PodcastDirectorySource] {
        var seen = Set<PodcastDirectorySource>()
        return sources.filter { seen.insert($0).inserted }
    }

    /// First occurrence per canonical URL wins its slot; later
    /// duplicates only backfill missing hints.
    public static func mergedCandidates(_ candidates: [DirectoryFeedCandidate]) -> [DirectoryFeedCandidate] {
        var indexByCanonicalURL: [String: Int] = [:]
        var merged: [DirectoryFeedCandidate] = []
        for candidate in candidates {
            let key = candidate.canonicalFeedURLString
            if let existingIndex = indexByCanonicalURL[key] {
                if merged[existingIndex].reportedEpisodeCount == nil {
                    merged[existingIndex].reportedEpisodeCount = candidate.reportedEpisodeCount
                }
                if merged[existingIndex].reportedUpdatedAt == nil {
                    merged[existingIndex].reportedUpdatedAt = candidate.reportedUpdatedAt
                }
            } else {
                indexByCanonicalURL[key] = merged.count
                merged.append(candidate)
            }
        }
        return merged
    }

    private static func canonicalFeedURLStrings(of result: DirectoryPodcastResult) -> Set<String> {
        var urls = Set(result.feedCandidates.map(\.canonicalFeedURLString))
        if let feedURL = result.feedURL {
            urls.insert(URLCanonicalizer.canonicalString(for: feedURL))
        }
        return urls
    }

    private static func normalizedGUID(_ guid: String?) -> String? {
        guard let value = guid?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }
}
