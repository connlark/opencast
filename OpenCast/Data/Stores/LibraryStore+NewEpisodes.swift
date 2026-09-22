import Foundation

// Per-show lookups for the Library's badges and Recent Episodes sort. Each
// reads the tracked episode list and reference date before the ignored
// release-order index, so a caller that missed still invalidates once
// either moves. Counts are derived on read rather than cached: the scan
// stops at the first episode older than the window, reading progress
// through `progressSummary` observes this context's in-place edits
// (deferred flushes included), and `progressRefetchRevision` covers edits
// a refetch imports from another context.
extension LibraryStore {
    /// Incomplete episodes released since the show was followed and within
    /// `LibraryNewEpisodeRules.recencyWindow`, as of
    /// `newEpisodeReferenceDate`. Missing progress counts as incomplete.
    func newEpisodeCount(for subscription: SubscriptionRecord) -> Int {
        let episodes = episodes
        _ = progressRefetchRevision
        guard let releaseDates = LibraryNewEpisodeRules.eligibleReleaseDates(
            subscribedAt: newEpisodeCutoffByFeedURL[subscription.feedURL] ?? subscription.subscribedAt,
            asOf: newEpisodeReferenceDate
        ),
            let releaseOrder = episodeReleaseOrderByPodcastID[subscription.feedURL]
        else {
            return 0
        }

        var count = 0
        for index in releaseOrder {
            let episode = episodes[index]
            guard let publishedAt = episode.publishedAt,
                  publishedAt <= releaseDates.upperBound
            else {
                continue
            }
            guard publishedAt >= releaseDates.lowerBound else {
                break
            }
            if !progressSummary(for: episode).isCompleted {
                count += 1
            }
        }
        return count
    }

    /// The newest cached episode already released at
    /// `newEpisodeReferenceDate`, regardless of played state; nil when the
    /// show has no dated, released episode.
    func latestReleasedEpisodeDate(forPodcastID podcastID: String) -> Date? {
        let episodes = episodes
        let asOf = newEpisodeReferenceDate
        return episodeReleaseOrderByPodcastID[podcastID]?
            .lazy
            .compactMap { episodes[$0].publishedAt }
            .first { $0 <= asOf }
    }
}
