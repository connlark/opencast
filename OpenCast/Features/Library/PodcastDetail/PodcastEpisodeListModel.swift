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

    /// One pass, so each episode's progress summary is looked up once per evaluation.
    /// `hiddenEpisodeIDs` leave the list only; the unplayed count and primary action still see
    /// every episode.
    static func make(
        episodes: [EpisodeListItemSnapshot],
        filter: PodcastEpisodeFilter,
        sortOrder: PodcastEpisodeSortOrder,
        library: LibraryStore,
        downloadRecords: @autoclosure () -> [EpisodeDownloadRecord],
        hiddenEpisodeIDs: Set<String> = []
    ) -> PodcastEpisodeListModel {
        // Download records are observed state; only Downloaded reads them.
        let downloadedEpisodeIDs = filter == .downloaded ? downloadRecords().completedEpisodeIDs : []
        let archivedEpisodeIDs = library.archivedEpisodeIDs

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
               !archivedEpisodeIDs.contains(episode.episodeID),
               let record = library.progressRecord(for: episode.episodeID),
               resumeUpdatedAt.map({ record.updatedAt > $0 }) ?? true {
                resumeEpisode = episode
                resumeUpdatedAt = record.updatedAt
            }

            if !hiddenEpisodeIDs.contains(episode.episodeID),
               filter.includes(
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
