import Foundation

/// Evaluates a smart playlist's rule over the subscribed library. MainActor:
/// progress lookups and the status clause read MainActor stores. Inputs a
/// rule does not need stay unread — the download records without Downloaded
/// Only, the reference date without an age clause, progress for All
/// Episodes — so an evaluation inside a view body observes only what the
/// rule depends on.
enum SmartPlaylistEvaluator {
    static func make(
        rule: PlaylistRule,
        library: LibraryStore,
        downloadRecords: @autoclosure () -> [EpisodeDownloadRecord],
        now: @autoclosure () -> Date
    ) -> [EpisodeListItemSnapshot] {
        let rule = rule.normalized()
        let minimumDuration = rule.minimumMinutes.map { TimeInterval($0) * 60 }
        let maximumDuration = rule.maximumMinutes.map { TimeInterval($0) * 60 }
        let checksLength = minimumDuration != nil || maximumDuration != nil
        let earliestPublishedAt: Date? = if let maximumAgeDays = rule.maximumAgeDays {
            now().addingTimeInterval(-TimeInterval(maximumAgeDays) * 86_400)
        } else {
            nil
        }
        let downloadedEpisodeIDs: Set<String>? = rule.downloadedOnly
            ? downloadRecords().completedEpisodeIDs
            : nil

        // Cheapest clauses first; the status clause reads progress lazily.
        func matches(_ episode: EpisodeListItemSnapshot) -> Bool {
            if checksLength {
                guard let duration = sanitizedDuration(episode.duration) else {
                    return false
                }
                if let minimumDuration, duration < minimumDuration {
                    return false
                }
                if let maximumDuration, duration >= maximumDuration {
                    return false
                }
            }
            if let earliestPublishedAt {
                guard let publishedAt = episode.publishedAt, publishedAt >= earliestPublishedAt else {
                    return false
                }
            }
            if let downloadedEpisodeIDs, !downloadedEpisodeIDs.contains(episode.episodeID) {
                return false
            }
            return rule.status.includes(progress: library.progressSummary(for: episode), isDownloaded: false)
        }

        // The episode ID settles ties, since Newest First has none of its own.
        let sortOrder = rule.sortOrder
        func precedes(_ lhs: EpisodeListItemSnapshot, _ rhs: EpisodeListItemSnapshot) -> Bool {
            sortOrder.areInIncreasingOrder(lhs, rhs)
                || (!sortOrder.areInIncreasingOrder(rhs, lhs) && lhs.episodeID < rhs.episodeID)
        }

        // Downloaded Only reads its handful of downloads instead of the whole
        // library. The library itself is already in Newest First order with
        // the same episode ID tie-break, so that order needs no sort and stops
        // at the limit.
        let showIDs = rule.podcastIDs.map { Set($0) }
        let source = downloadedEpisodeIDs.map { episodeIDs in
            episodeIDs.compactMap { library.episode(with: $0) }
        } ?? library.episodes
        let isInSourceOrder = downloadedEpisodeIDs == nil && sortOrder == .newestFirst
        let limit = rule.limit
        var episodes: [EpisodeListItemSnapshot] = []
        for episode in source {
            if let showIDs, !showIDs.contains(episode.podcastID) {
                continue
            }
            if isInSourceOrder {
                guard matches(episode) else {
                    continue
                }
                episodes.append(episode)
                if episodes.count == limit {
                    break
                }
                continue
            }
            guard let limit else {
                if matches(episode) {
                    episodes.append(episode)
                }
                continue
            }
            // A bounded, ordered top-`limit` buffer; the order check runs
            // before the clauses so a full buffer skips progress lookups.
            if episodes.count == limit, let last = episodes.last, !precedes(episode, last) {
                continue
            }
            guard matches(episode) else {
                continue
            }
            if episodes.count == limit {
                episodes.removeLast()
            }
            episodes.insert(episode, at: insertionIndex(of: episode, in: episodes, by: precedes))
        }
        if !isInSourceOrder, limit == nil {
            episodes.sort(by: precedes)
        }
        return episodes
    }

    /// The first index whose episode `episode` precedes, found by binary
    /// search over the already-ordered buffer.
    private static func insertionIndex(
        of episode: EpisodeListItemSnapshot,
        in episodes: [EpisodeListItemSnapshot],
        by precedes: (EpisodeListItemSnapshot, EpisodeListItemSnapshot) -> Bool
    ) -> Int {
        var lower = 0
        var upper = episodes.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if precedes(episode, episodes[middle]) {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        return lower
    }
}
