import Foundation

/// The Inbox rows under the current filter, Hide Up Next and the view Show
/// Archived picks: off, the Inbox (every episode not archived); on, the
/// archive (only the archived ones). Built in `InboxView.body` rather than
/// cached, so per-record Observation moves an episode between filters the
/// moment a progress flush changes its state.
struct InboxEpisodeListModel {
    let episodes: [EpisodeListItemSnapshot]
    /// Every Inbox episode, archived or not, so an Inbox whose rows are all
    /// archived, or an empty archive, reads as filtered empty rather than
    /// empty.
    let totalEpisodeCount: Int
    let hasMore: Bool

    var isFilteredEmpty: Bool {
        episodes.isEmpty && totalEpisodeCount > 0 && !hasMore
    }

    /// Both views read the archived set. The download, queue and
    /// playing-episode inputs are autoclosures: they are observed state, and
    /// reading one the filter does not need would subscribe the whole Inbox
    /// list to it. All Episodes with Hide Up Next off reads the archived set
    /// and nothing else; the Inbox view with nothing archived returns the
    /// input untouched.
    /// When `visibleEpisodeCount` is supplied, the scan stops after one extra
    /// match and `hasMore` drives the continuation row.
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
            // Hide Up Next hides what the player already holds: the queue
            // and the playing episode, queued or not.
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
