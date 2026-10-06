/// The builder's output: the rendered prompt and exactly what it sent.
nonisolated struct PlaylistOrganizerInput: Equatable, Sendable {
    enum Rung: String, Equatable, Sendable, CaseIterable {
        case snippets
        case titles
        case compact
    }

    /// The full rendered prompt: the template around `lines`.
    var prompt: String
    /// The numbered lines, newline-joined, in index order. Each starts with
    /// its line number, which is the episode index unless the lines are gapped.
    var lines: String
    var scope: PlaylistOrganizerScope
    var rung: Rung
    /// Ascending episode indices; exactly the episodes in `lines`.
    var candidateIndices: [Int]
    /// The sent episodes only. Returned numbers resolve against this through
    /// `episodeIndex(forLineNumber:)`, never a fresh library read.
    var episodesByIndex: [Int: PlaylistOrganizerEpisode]
    var framedTokenCount: Int
    /// Non-nil when retrieval chose the candidates.
    var window: EpisodeCandidateWindow?
    /// 0 when no retrieval ran.
    var retrievalMilliseconds: Double
    /// The instructions sent with this input (standard or the simpler answer's).
    var instructions = PlaylistOrganizerPrompt.instructions
    var answerStyle = PlaylistOrganizerAnswerStyle.standard
    /// Line number -> episode index when the lines are gapped; empty when each line starts with its index.
    var indexByLineNumber: [Int: Int] = [:]
    /// Each sent episode's title with a show-wide prefix ("Show EP 12 — ")
    /// dropped, for naming a simpler answer's playlists.
    var shortTitlesByIndex: [Int: String] = [:]

    /// The episode index a number in the model's answer stands for, or nil.
    func episodeIndex(forLineNumber number: Int) -> Int? {
        indexByLineNumber.isEmpty ? number : indexByLineNumber[number]
    }
}
