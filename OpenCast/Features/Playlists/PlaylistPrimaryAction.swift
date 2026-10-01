import Foundation

/// The playlist hero's Play label: Resume when the episode Play would start
/// is already in progress, otherwise Play.
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

    /// Looks at the first resolvable item that is not marked played, the same
    /// episode `OpenCastAppModel.playPlaylist` starts without shuffle.
    static func resolve(items: [PlaylistResolvedItem], library: LibraryStore) -> PlaylistPrimaryAction {
        let firstPlayable = items.lazy
            .compactMap(\.snapshot)
            .first { library.progressRecord(for: $0.episodeID)?.isPlayed != true }
        guard let firstPlayable, library.progressSummary(for: firstPlayable).hasVisibleProgress else {
            return .play
        }
        return .resume
    }

    /// A smart playlist's label over its evaluation, or nil when Play has
    /// nothing to start. Smart playlists use the Episodes chip's definition
    /// of unplayed, which also counts a position at the end as played, so
    /// the first episode not completed is the one `playPlaylist` starts.
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
