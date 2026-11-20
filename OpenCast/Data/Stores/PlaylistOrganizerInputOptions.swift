nonisolated struct PlaylistOrganizerInputOptions: Equatable, Sendable {
    enum Candidates: Equatable, Sendable {
        case automatic
        case full
        case lexical(query: String, limit: Int)
        case explicit([Int])
        case newest(Int)
    }

    enum LineNumbers: Equatable, Sendable {
        /// Each line starts with its episode index (0 = newest).
        case index
        /// A nil seed draws a random one.
        case gapped(seed: UInt64?)
    }

    var candidates = Candidates.automatic
    /// Ladder order; a single element forces that rung.
    var rungs = PlaylistOrganizerInput.Rung.allCases
    var budget = PlaylistOrganizerInputBuilder.defaultTokenBudget
    var lineNumbers = LineNumbers.index
}
