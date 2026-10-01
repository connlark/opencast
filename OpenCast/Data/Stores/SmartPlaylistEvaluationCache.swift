import Foundation

/// One memoized evaluation per smart playlist. Deliberately not observable:
/// views read it during `body`, and their invalidation comes from the tokens
/// they read to build the key, never from this cache's writes.
final class SmartPlaylistEvaluationCache {
    private var entries: [String: (key: SmartPlaylistEvaluationKey, evaluation: SmartPlaylistEvaluation)] = [:]
    /// Evaluations computed since creation, so tests can tell a hit from a
    /// recompute.
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
