import Foundation

enum PodcastPrimaryAction: Equatable {
    case resume(EpisodeListItemSnapshot)
    case playLatest(EpisodeListItemSnapshot)

    var episode: EpisodeListItemSnapshot {
        switch self {
        case .resume(let episode), .playLatest(let episode):
            episode
        }
    }

    var title: String {
        switch self {
        case .resume:
            "Resume"
        case .playLatest:
            "Play Latest"
        }
    }

    static func resolve(
        episodes: [EpisodeListItemSnapshot],
        library: LibraryStore
    ) -> PodcastPrimaryAction? {
        var resumeEpisode: EpisodeListItemSnapshot?
        var resumeUpdatedAt: Date?

        for episode in episodes {
            let progress = library.progressSummary(for: episode)
            guard progress.hasVisibleProgress,
                  let record = library.progressRecord(for: episode.episodeID)
            else {
                continue
            }

            if let resumeUpdatedAt, record.updatedAt <= resumeUpdatedAt {
                continue
            }
            resumeEpisode = episode
            resumeUpdatedAt = record.updatedAt
        }

        if let resumeEpisode {
            return .resume(resumeEpisode)
        }
        if let unplayedEpisode = episodes.first(where: { !library.progressSummary(for: $0).isCompleted }) {
            return .playLatest(unplayedEpisode)
        }
        return episodes.first.map(PodcastPrimaryAction.playLatest)
    }
}
