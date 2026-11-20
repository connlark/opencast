import Foundation

// Each lookup reads the observed `episodes` and reference date before the ignored release-order
// index, so a view that found nothing still invalidates when either moves. Reading
// `progressRefetchRevision` tracks progress a refetch imports from another context.
extension LibraryStore {
    func newEpisodeCount(for subscription: SubscriptionRecord) -> Int {
        let episodes = episodes
        let archivedEpisodeIDs = archivedEpisodeIDs
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
                  publishedAt.timeIntervalSinceReferenceDate <= releaseDates.upperBound.timeIntervalSinceReferenceDate
            else {
                continue
            }
            guard publishedAt.timeIntervalSinceReferenceDate >= releaseDates.lowerBound.timeIntervalSinceReferenceDate else {
                break
            }
            if !archivedEpisodeIDs.contains(episode.episodeID),
               !progressSummary(for: episode).isCompleted {
                count += 1
            }
        }
        return count
    }

    func latestReleasedEpisodeDate(forPodcastID podcastID: String) -> Date? {
        let episodes = episodes
        let asOf = newEpisodeReferenceDate
        return episodeReleaseOrderByPodcastID[podcastID]?
            .lazy
            .compactMap { episodes[$0].publishedAt }
            .first { $0.timeIntervalSinceReferenceDate <= asOf.timeIntervalSinceReferenceDate }
    }

    func newestReleasedEpisode(forPodcastID podcastID: String, asOf: Date) -> EpisodeListItemSnapshot? {
        let episodes = episodes
        return episodeReleaseOrderByPodcastID[podcastID]?
            .lazy
            .map { episodes[$0] }
            .first { ($0.publishedAt ?? .distantFuture).timeIntervalSinceReferenceDate <= asOf.timeIntervalSinceReferenceDate }
    }

    func releasedEpisodes(
        forPodcastID podcastID: String,
        publishedAfter: Date,
        asOf: Date
    ) -> [EpisodeListItemSnapshot] {
        let episodes = episodes
        var released: [EpisodeListItemSnapshot] = []
        for index in episodeReleaseOrderByPodcastID[podcastID] ?? [] {
            let episode = episodes[index]
            guard let publishedAt = episode.publishedAt,
                  publishedAt.timeIntervalSinceReferenceDate <= asOf.timeIntervalSinceReferenceDate
            else {
                continue
            }
            guard publishedAt > publishedAfter else {
                break
            }
            released.append(episode)
        }
        return released
    }
}
