import Foundation

enum PlaylistPrimaryAction: Equatable {
    case play
    case resume

    var title: String {
        switch self {
        case .play:
            "Play"
        case .resume:
            "Resume"
        }
    }

    /// Must pick the episode `OpenCastAppModel.playPlaylist` starts without shuffle.
    static func resolve(items: [PlaylistResolvedItem], library: LibraryStore) -> PlaylistPrimaryAction {
        let firstPlayable = items.lazy
            .compactMap(\.snapshot)
            .first { library.progressRecord(for: $0.episodeID)?.isPlayed != true }
        guard let firstPlayable, library.progressSummary(for: firstPlayable).hasVisibleProgress else {
            return .play
        }
        return .resume
    }

    /// Uses the Episodes chip's unplayed, which counts a position at the end as played, so it
    /// matches the episode `playPlaylist` starts. Nil when Play has nothing to start.
    static func resolve(smartEpisodes episodes: [EpisodeListItemSnapshot], library: LibraryStore) -> PlaylistPrimaryAction? {
        for episode in episodes {
            let progress = library.progressSummary(for: episode)
            if !progress.isCompleted {
                return progress.hasVisibleProgress ? .resume : .play
            }
        }
        return nil
    }
}
