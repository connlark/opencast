import Foundation

nonisolated struct SmartPlaylistEvaluation: Equatable, Sendable {
    static let empty = SmartPlaylistEvaluation(episodes: [])

    let episodes: [EpisodeListItemSnapshot]
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
