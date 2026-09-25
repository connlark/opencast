import Foundation

/// The Inbox rows under the current filter and Hide Up Next toggle. Built in
/// `InboxView.body` rather than cached, so per-record Observation moves an
/// episode between filters the moment a progress flush changes its state.
struct InboxEpisodeListModel {
    let episodes: [EpisodeListItemSnapshot]
    let totalEpisodeCount: Int
    let hasMore: Bool

    var isFilteredEmpty: Bool {
        episodes.isEmpty && totalEpisodeCount > 0 && !hasMore
    }

    /// The download, queue and playing-episode inputs are autoclosures: they
    /// are observed state, and reading one the filter does not need would
    /// subscribe the whole Inbox list to it. All Episodes with the toggle off
    /// returns the input untouched and reads nothing.
    /// When `visibleEpisodeCount` is supplied, the scan stops after one extra
    /// match and `hasMore` drives the continuation row.
    static func make(
        episodes: [EpisodeListItemSnapshot],
        filter: PodcastEpisodeFilter,
        hidesQueuedEpisodes: Bool,
        library: LibraryStore,
        downloadRecords: @autoclosure () -> [EpisodeDownloadRecord],
        queuedEpisodeIDs: @autoclosure () -> Set<String>,
        playingEpisodeID: @autoclosure () -> String?,
        visibleEpisodeCount: Int? = nil
    ) -> InboxEpisodeListModel {
        guard filter != .all || hidesQueuedEpisodes else {
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
        var hiddenEpisodeIDs: Set<String> = []
        if hidesQueuedEpisodes {
            hiddenEpisodeIDs = queuedEpisodeIDs()
            // A stale queue entry for the episode that is playing must not
            // hide the row the listener is on.
            if let playingEpisodeID = playingEpisodeID() {
                hiddenEpisodeIDs.remove(playingEpisodeID)
            }
        }

        let visibleCount = visibleEpisodeCount.map { max($0, 0) }
        var visibleEpisodes: [EpisodeListItemSnapshot] = []
        var hasMore = false
        for episode in episodes {
            guard !hiddenEpisodeIDs.contains(episode.episodeID),
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
