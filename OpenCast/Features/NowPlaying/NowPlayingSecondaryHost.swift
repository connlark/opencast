/// Where a secondary destination's view is shown: in its own sheet, as
/// always, or embedded in the Now Playing pane beside the player.
nonisolated enum NowPlayingSecondaryHost: Equatable, Sendable {
    case sheet
    case pane

    /// A sheet closes once the user plays a queued episode or picks a
    /// chapter; the pane keeps itself and the player on screen.
    var dismissesAfterSelection: Bool {
        self == .sheet
    }

    /// Only a sheet offers Done.
    var showsDoneButton: Bool {
        self == .sheet
    }
}
