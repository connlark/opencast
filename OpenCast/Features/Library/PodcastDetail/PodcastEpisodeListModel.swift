struct PodcastEpisodeListModel {
    let episodes: [EpisodeListItemSnapshot]
    let totalEpisodeCount: Int
    let animationKey: [String]

    var isFilteredEmpty: Bool {
        episodes.isEmpty && totalEpisodeCount > 0
    }

    static func make(
        episodes: [EpisodeListItemSnapshot],
        filter: PodcastEpisodeFilter,
        sortOrder: PodcastEpisodeSortOrder,
        library: LibraryStore,
        downloadRecords: [EpisodeDownloadRecord]
    ) -> PodcastEpisodeListModel {
        let downloadedEpisodeIDs = Set(
            downloadRecords.compactMap { record in
                record.state == .completed ? record.episodeID : nil
            }
        )
        var visibleEpisodes = episodes.filter { episode in
            let progress = library.progressSummary(for: episode)
            return switch filter {
            case .all:
                true
            case .unplayed:
                !progress.isCompleted
            case .inProgress:
                progress.hasVisibleProgress
            case .played:
                progress.isCompleted
            case .downloaded:
                downloadedEpisodeIDs.contains(episode.episodeID)
            }
        }

        if sortOrder != .newestFirst {
            visibleEpisodes.sort(by: sortOrder.areInIncreasingOrder)
        }

        return PodcastEpisodeListModel(
            episodes: visibleEpisodes,
            totalEpisodeCount: episodes.count,
            animationKey: visibleEpisodes.map(\.episodeID)
        )
    }
}
