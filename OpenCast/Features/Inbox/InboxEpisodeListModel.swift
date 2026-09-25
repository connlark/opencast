import Foundation

/// The Inbox rows under the current filter and Hide Up Next toggle. Built in
/// `InboxView.body` rather than cached, so per-record Observation moves an
/// episode between filters the moment a progress flush changes its state.
struct InboxEpisodeListModel {
    let episodes: [EpisodeListItemSnapshot]
    let totalEpisodeCount: Int

    var isFilteredEmpty: Bool {
        episodes.isEmpty && totalEpisodeCount > 0
    }

    /// The download, queue and playing-episode inputs are autoclosures: they
    /// are observed state, and reading one the filter does not need would
    /// subscribe the whole Inbox list to it. All Episodes with the toggle off
    /// returns the input untouched and reads nothing.
    static func make(
        episodes: [EpisodeListItemSnapshot],
        filter: PodcastEpisodeFilter,
        hidesQueuedEpisodes: Bool,
        library: LibraryStore,
        downloadRecords: @autoclosure () -> [EpisodeDownloadRecord],
        queuedEpisodeIDs: @autoclosure () -> Set<String>,
        playingEpisodeID: @autoclosure () -> String?
    ) -> InboxEpisodeListModel {
        guard filter != .all || hidesQueuedEpisodes else {
            return InboxEpisodeListModel(episodes: episodes, totalEpisodeCount: episodes.count)
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

        let visibleEpisodes = episodes.filter { episode in
            !hiddenEpisodeIDs.contains(episode.episodeID)
                && filter.includes(
                    progress: library.progressSummary(for: episode),
                    isDownloaded: downloadedEpisodeIDs.contains(episode.episodeID)
                )
        }
        return InboxEpisodeListModel(episodes: visibleEpisodes, totalEpisodeCount: episodes.count)
    }
}
