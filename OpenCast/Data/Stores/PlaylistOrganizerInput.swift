nonisolated struct PlaylistOrganizerInput: Equatable, Sendable {
    enum Rung: String, Equatable, Sendable, CaseIterable {
        case snippets
        case titles
        case compact
    }

    var prompt: String
    /// Newline-joined in index order; each line starts with its line number.
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
    var instructions = PlaylistOrganizerPrompt.instructions
    var answerStyle = PlaylistOrganizerAnswerStyle.standard
    /// Empty when each line starts with its episode index.
    var indexByLineNumber: [Int: Int] = [:]
    /// Titles with any show-wide prefix ("Show EP 12 — ") dropped.
    var shortTitlesByIndex: [Int: String] = [:]

    func episodeIndex(forLineNumber number: Int) -> Int? {
        indexByLineNumber.isEmpty ? number : indexByLineNumber[number]
    }
}
