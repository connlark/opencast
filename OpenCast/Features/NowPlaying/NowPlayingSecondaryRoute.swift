nonisolated enum NowPlayingSecondaryDestination: Equatable, Sendable {
    case upNext
    case chapters
    case transcript
    case showDescription
}

nonisolated enum NowPlayingSecondaryRoute: Equatable, Sendable {
    case selectPane(NowPlayingSecondaryPane)
    case presentSheet(PlayerUtilitySheet)
    case openEpisode
    case generateTranscript

    init(destination: NowPlayingSecondaryDestination, paneStyle: NowPlayingSecondaryPaneStyle) {
        guard paneStyle == .beside else {
            self = switch destination {
            case .upNext:
                .presentSheet(.upNext)
            case .chapters:
                .presentSheet(.chapters)
            case .transcript:
                .presentSheet(.transcript)
            case .showDescription:
                .openEpisode
            }
            return
        }
        self = switch destination {
        case .upNext:
            .selectPane(.upNext)
        case .chapters:
            .selectPane(.chapters)
        case .transcript:
            .selectPane(.transcript)
        case .showDescription:
            .selectPane(.showNotes)
        }
    }

    static func transcriptAction(hasCompletedTranscript: Bool, paneStyle: NowPlayingSecondaryPaneStyle) -> Self {
        hasCompletedTranscript ? Self(destination: .transcript, paneStyle: paneStyle) : .generateTranscript
    }
}
