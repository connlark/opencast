nonisolated enum NowPlayingSecondaryHost: Equatable, Sendable {
    case sheet
    case pane

    var dismissesAfterSelection: Bool {
        self == .sheet
    }

    var showsDoneButton: Bool {
        self == .sheet
    }
}
