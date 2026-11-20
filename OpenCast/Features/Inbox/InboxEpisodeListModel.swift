import Foundation

/// Built in `InboxView.body`, not cached, so per-record Observation refilters an episode the
/// moment a progress flush changes its state.
struct InboxEpisodeListModel {
    let episodes: [EpisodeListItemSnapshot]
    /// Every Inbox episode, archived or not.
    let totalEpisodeCount: Int
    let hasMore: Bool

    var isFilteredEmpty: Bool {
        episodes.isEmpty && totalEpisodeCount > 0 && !hasMore
    }

    /// The download, queue and playing-episode inputs are autoclosures: each is observed state, and
    /// reading one the filter does not need subscribes the whole Inbox list to it.
    static func make(
        episodes: [EpisodeListItemSnapshot],
        filter: PodcastEpisodeFilter,
        hidesQueuedEpisodes: Bool,
        showsArchivedEpisodes: Bool,
        library: LibraryStore,
        downloadRecords: @autoclosure () -> [EpisodeDownloadRecord],
        queuedEpisodeIDs: @autoclosure () -> Set<String>,
        playingEpisodeID: @autoclosure () -> String?,
        archivedEpisodeIDs: Set<String>,
        visibleEpisodeCount: Int? = nil
    ) -> InboxEpisodeListModel {
        var hiddenEpisodeIDs = Set<String>()
        if hidesQueuedEpisodes {
            hiddenEpisodeIDs.formUnion(queuedEpisodeIDs())
            if let playingEpisodeID = playingEpisodeID() {
                hiddenEpisodeIDs.insert(playingEpisodeID)
            }
        }

        guard showsArchivedEpisodes
            || filter != .all
            || !archivedEpisodeIDs.isEmpty
            || !hiddenEpisodeIDs.isEmpty
        else {
            guard let visibleEpisodeCount else {
                return InboxEpisodeListModel(episodes: episodes, totalEpisodeCount: episodes.count, hasMore: false)
            }
            let visibleCount = max(visibleEpisodeCount, 0)
            let visibleEpisodes = Array(episodes.prefix(visibleCount))
            return InboxEpisodeListModel(
                episodes: visibleEpisodes,
                totalEpisodeCount: episodes.count,
                hasMore: visibleEpisodes.count < episodes.count
            )
        }

        let downloadedEpisodeIDs = filter == .downloaded ? downloadRecords().completedEpisodeIDs : []
        let visibleCount = visibleEpisodeCount.map { max($0, 0) }
        var visibleEpisodes: [EpisodeListItemSnapshot] = []
        var hasMore = false
        for episode in episodes {
            guard archivedEpisodeIDs.contains(episode.episodeID) == showsArchivedEpisodes,
                  !hiddenEpisodeIDs.contains(episode.episodeID),
                  filter.includes(
                      progress: library.progressSummary(for: episode),
                      isDownloaded: downloadedEpisodeIDs.contains(episode.episodeID)
                  )
            else {
                continue
            }

            if let visibleCount, visibleEpisodes.count >= visibleCount {
                hasMore = true
                break
            }
            visibleEpisodes.append(episode)
        }
        return InboxEpisodeListModel(
            episodes: visibleEpisodes,
            totalEpisodeCount: episodes.count,
            hasMore: hasMore
        )
    }
}
