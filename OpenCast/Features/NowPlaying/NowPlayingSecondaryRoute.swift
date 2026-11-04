/// The four entry points that can reach the secondary pane.
nonisolated enum NowPlayingSecondaryDestination: Equatable, Sendable {
    /// The utility row's Up Next.
    case upNext
    /// The chapter strip's action.
    case chapters
    /// A completed transcript's action.
    case transcript
    /// The More menu's Show Description.
    case showDescription
}

/// What an entry point does under the current arrangement. Beside the
/// player, it selects the pane's mode; everywhere else it keeps today's
/// behaviour: Up Next and Chapters as their sheets, Transcript as its
/// large sheet, Show Description by opening the episode. Speed, Sleep and
/// Private Notes never route here.
nonisolated enum NowPlayingSecondaryRoute: Equatable, Sendable {
    case selectPane(NowPlayingSecondaryPane)
    case presentSheet(PlayerUtilitySheet)
    case openEpisode
    /// No completed transcript: the existing request flow generates one.
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

    /// The transcript action: a completed transcript routes like any entry
    /// point; a missing one keeps the request flow in every arrangement.
    static func transcriptAction(hasCompletedTranscript: Bool, paneStyle: NowPlayingSecondaryPaneStyle) -> Self {
        hasCompletedTranscript ? Self(destination: .transcript, paneStyle: paneStyle) : .generateTranscript
    }
}
