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
}
