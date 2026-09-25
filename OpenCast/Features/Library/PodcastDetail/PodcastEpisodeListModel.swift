import Foundation

struct PodcastEpisodeListModel {
    let episodes: [EpisodeListItemSnapshot]
    let totalEpisodeCount: Int
    let animationKey: [String]
    let unplayedEpisodeCount: Int
    let primaryAction: PodcastPrimaryAction?

    var isFilteredEmpty: Bool {
        episodes.isEmpty && totalEpisodeCount > 0
    }

    /// One pass over the show's episodes derives the filtered list, the
    /// unplayed count, and the primary action together — each episode's
    /// progress summary is looked up exactly once per evaluation.
    static func make(
        episodes: [EpisodeListItemSnapshot],
        filter: PodcastEpisodeFilter,
        sortOrder: PodcastEpisodeSortOrder,
        library: LibraryStore,
        downloadRecords: @autoclosure () -> [EpisodeDownloadRecord]
    ) -> PodcastEpisodeListModel {
        // Download records are observed state; only Downloaded reads them.
        let downloadedEpisodeIDs = filter == .downloaded ? downloadRecords().completedEpisodeIDs : []

        var visibleEpisodes: [EpisodeListItemSnapshot] = []
        var unplayedEpisodeCount = 0
        var firstUnplayedEpisode: EpisodeListItemSnapshot?
        var resumeEpisode: EpisodeListItemSnapshot?
        var resumeUpdatedAt: Date?

        for episode in episodes {
            let progress = library.progressSummary(for: episode)

            if !progress.isCompleted {
                unplayedEpisodeCount += 1
                if firstUnplayedEpisode == nil {
                    firstUnplayedEpisode = episode
                }
            }

            if progress.hasVisibleProgress,
               let record = library.progressRecord(for: episode.episodeID),
               resumeUpdatedAt.map({ record.updatedAt > $0 }) ?? true {
                resumeEpisode = episode
                resumeUpdatedAt = record.updatedAt
            }

            if filter.includes(
                progress: progress,
                isDownloaded: downloadedEpisodeIDs.contains(episode.episodeID)
            ) {
                visibleEpisodes.append(episode)
            }
        }

        if sortOrder != .newestFirst {
            visibleEpisodes.sort(by: sortOrder.areInIncreasingOrder)
        }

        let primaryAction: PodcastPrimaryAction? = if let resumeEpisode {
            .resume(resumeEpisode)
        } else if let firstUnplayedEpisode {
            .playLatest(firstUnplayedEpisode)
        } else {
            episodes.first.map(PodcastPrimaryAction.playLatest)
        }

        return PodcastEpisodeListModel(
            episodes: visibleEpisodes,
            totalEpisodeCount: episodes.count,
            animationKey: visibleEpisodes.map(\.episodeID),
            unplayedEpisodeCount: unplayedEpisodeCount,
            primaryAction: primaryAction
        )
    }
}
