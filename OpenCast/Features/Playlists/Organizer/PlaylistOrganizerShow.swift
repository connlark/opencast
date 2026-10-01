import Foundation

/// One show's episodes as the organizer sheet captured them, once per sheet,
/// so every index the model or the episode catalog returns resolves against
/// the same list even if the library refreshes meanwhile.
nonisolated struct PlaylistOrganizerShow: Sendable {
    let title: String
    /// Newest first; an episode's `index` is its position here.
    let episodes: [PlaylistOrganizerEpisode]
    /// Library snapshots carrying the show's artwork where an episode has
    /// none, so saved items keep a cover.
    let snapshotsByEpisodeID: [String: EpisodeListItemSnapshot]
    let positionsByEpisodeID: [String: Int]

    init(title: String, episodes: [PlaylistOrganizerEpisode], snapshots: [EpisodeListItemSnapshot]) {
        self.title = title
        self.episodes = episodes
        snapshotsByEpisodeID = Dictionary(
            snapshots.map { ($0.episodeID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        positionsByEpisodeID = Dictionary(
            episodes.map { ($0.episodeID, $0.index) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func snapshot(atPosition position: Int) -> EpisodeListItemSnapshot? {
        guard episodes.indices.contains(position) else {
            return nil
        }
        return snapshotsByEpisodeID[episodes[position].episodeID]
    }
}
