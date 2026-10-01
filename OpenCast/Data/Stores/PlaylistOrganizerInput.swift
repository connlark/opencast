/// The builder's output: the rendered prompt and exactly what it sent.
nonisolated struct PlaylistOrganizerInput: Equatable, Sendable {
    enum Rung: String, Equatable, Sendable, CaseIterable {
        case snippets
        case titles
        case compact
    }

    /// The full rendered prompt: the template around `lines`.
    var prompt: String
    /// The numbered lines, newline-joined, in index order.
    var lines: String
    var scope: PlaylistOrganizerScope
    var rung: Rung
    /// Ascending; exactly the indices in `lines`.
    var candidateIndices: [Int]
    /// The sent episodes only. Returned indices resolve against this, never
    /// a fresh library read.
    var episodesByIndex: [Int: PlaylistOrganizerEpisode]
    var framedTokenCount: Int
    /// Non-nil when retrieval chose the candidates.
    var window: EpisodeCandidateWindow?
    /// 0 when no retrieval ran.
    var retrievalMilliseconds: Double
}
