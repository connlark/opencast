public nonisolated enum PlaybackSeekIntent: Sendable, Equatable {
    case scrub
    case skipButton
    case autoSkip
    case restore
}
