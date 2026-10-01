import Foundation

/// A smart playlist's evaluated episodes in rule order, with the figures the
/// collection and hero lines show.
nonisolated struct SmartPlaylistEvaluation: Equatable, Sendable {
    static let empty = SmartPlaylistEvaluation(episodes: [])

    let episodes: [EpisodeListItemSnapshot]
    /// Sum of the episodes' positive durations; episodes without one add
    /// nothing.
    let totalDuration: TimeInterval

    var count: Int {
        episodes.count
    }

    init(episodes: [EpisodeListItemSnapshot]) {
        self.episodes = episodes
        totalDuration = episodes.reduce(0) { total, episode in
            total + (sanitizedDuration(episode.duration) ?? 0)
        }
    }
}
