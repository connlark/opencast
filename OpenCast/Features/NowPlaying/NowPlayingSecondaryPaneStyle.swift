/// How an arrangement offers the secondary pane.
nonisolated enum NowPlayingSecondaryPaneStyle: Equatable, Sendable {
    /// No pane: Up Next, Chapters, Transcript and Show Description keep their
    /// existing sheets and navigation. The selection is still remembered.
    case entryPointsOnly
    /// The pane beside the player.
    case beside
    /// A row naming the remembered mode below the controls; expanding it
    /// shows the same pane inline. The pane collapses; it never vanishes.
    case disclosure
}
