import Foundation

/// Not observable on purpose: views read it during `body`, and only the tokens they read to
/// build the key may invalidate them, never this cache's writes.
final class SmartPlaylistEvaluationCache {
    private var entries: [String: (key: SmartPlaylistEvaluationKey, evaluation: SmartPlaylistEvaluation)] = [:]
    private(set) var computeCount = 0

    func evaluation(
        for playlistID: String,
        key: SmartPlaylistEvaluationKey,
        compute: () -> [EpisodeListItemSnapshot]
    ) -> SmartPlaylistEvaluation {
        if let entry = entries[playlistID], entry.key == key {
            return entry.evaluation
        }

        let evaluation = SmartPlaylistEvaluation(episodes: compute())
        computeCount += 1
        entries[playlistID] = (key: key, evaluation: evaluation)
        return evaluation
    }

    func remove(_ playlistID: String) {
        entries[playlistID] = nil
    }

    func removeAll() {
        entries.removeAll()
    }
}
