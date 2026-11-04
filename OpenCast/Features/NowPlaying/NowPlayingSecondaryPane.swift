/// The secondary pane's four modes. The selection lives in scene storage
/// under `sceneStorageKey`, so it survives live pose changes and comes back
/// with the scene's saved state.
nonisolated enum NowPlayingSecondaryPane: String, CaseIterable, Identifiable, Sendable {
    case upNext
    case transcript
    case chapters
    case showNotes

    static let sceneStorageKey = "nowPlayingSecondaryPane"
    static let pickerAccessibilityIdentifier = "Now Playing Secondary Pane"

    /// A missing or unrecognized stored value is Up Next.
    init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .upNext
    }

    /// The pane mode an open utility sheet already shows, if any.
    init?(sheet: PlayerUtilitySheet) {
        switch sheet {
        case .upNext:
            self = .upNext
        case .chapters:
            self = .chapters
        case .transcript:
            self = .transcript
        case .speed, .sleep, .notes, .soundLab:
            return nil
        }
    }

    var id: Self { self }

    var title: String {
        switch self {
        case .upNext:
            "Up Next"
        case .transcript:
            "Transcript"
        case .chapters:
            "Chapters"
        case .showNotes:
            "Show Notes"
        }
    }

    var systemImage: String {
        switch self {
        case .upNext:
            "text.line.first.and.arrowtriangle.forward"
        case .transcript:
            "quote.bubble"
        case .chapters:
            "list.bullet"
        case .showNotes:
            "doc.plaintext"
        }
    }
}
