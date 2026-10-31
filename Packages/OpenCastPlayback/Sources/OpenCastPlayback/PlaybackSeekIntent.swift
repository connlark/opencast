public nonisolated enum PlaybackSeekIntent: Sendable, Equatable {
    case scrub
    case skipButton
    case autoSkip
    case restore
    /// A jump to a chapter start. A tolerant seek can settle a frame before
    /// the boundary, which the chapter bar reads as the previous chapter.
    case chapter

    /// Whether the player seeks with zero tolerance. Restores and chapter
    /// jumps must land where they aim; the rest trade exactness for speed.
    public var landsExactly: Bool {
        switch self {
        case .restore, .chapter:
            true
        case .scrub, .skipButton, .autoSkip:
            false
        }
    }

    /// Whether the seek is a listener's command, which takes over from a
    /// temporary pause (the note editor's) so dismissing the editor does not
    /// resume at the new position. The ad skipper (`autoSkip`) and the
    /// position restore on load (`restore`; `load` already advances the
    /// revision) are the player's own moves, not the listener's, so they
    /// leave a temporary pause in place.
    public var supersedesTemporaryPause: Bool {
        switch self {
        case .scrub, .skipButton, .chapter:
            true
        case .autoSkip, .restore:
            false
        }
    }
}
