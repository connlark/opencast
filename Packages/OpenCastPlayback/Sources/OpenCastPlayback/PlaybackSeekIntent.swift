public nonisolated enum PlaybackSeekIntent: Sendable, Equatable {
    case scrub
    case skipButton
    case autoSkip
    case restore
    /// A tolerant seek can settle a frame before the boundary, which reads as the previous chapter.
    case chapter

    public var landsExactly: Bool {
        switch self {
        case .restore, .chapter:
            true
        case .scrub, .skipButton, .autoSkip:
            false
        }
    }

    /// A listener's seek takes over from a temporary pause, so dismissing its owner does not
    /// resume at the new position. `autoSkip` and `restore` are the player's own moves and leave
    /// the pause in place.
    public var supersedesTemporaryPause: Bool {
        switch self {
        case .scrub, .skipButton, .chapter:
            true
        case .autoSkip, .restore:
            false
        }
    }
}
