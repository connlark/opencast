/// How the builder chooses and renders the episode lines. Production uses
/// the defaults; the DEBUG evaluation runner forces variants.
nonisolated struct PlaylistOrganizerInputOptions: Equatable, Sendable {
    enum Candidates: Equatable, Sendable {
        /// A long show with an informative request sends its best matches and
        /// suggested groups its newest episodes; everything else sends the
        /// whole show.
        case automatic
        case full
        /// The lexical top `limit` for `query`, with no word-vector fill.
        case lexical(query: String, limit: Int)
        case explicit([Int])
        case newest(Int)
    }

    enum LineNumbers: Equatable, Sendable {
        /// Each line starts with its episode index (0 = newest).
        case index
        /// Increasing numbers with gaps of 1–3 from a seeded generator (a random
        /// seed when nil), so matching episodes never read as a countdown. The
        /// silent resend after a recitation decline uses them.
        case gapped(seed: UInt64?)
    }

    var candidates = Candidates.automatic
    /// Ladder order; a single element forces that rung.
    var rungs = PlaylistOrganizerInput.Rung.allCases
    var budget = PlaylistOrganizerInputBuilder.defaultTokenBudget
    var lineNumbers = LineNumbers.index
}
