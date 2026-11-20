nonisolated struct NowPlayingSoundLabAdFreePassRowModel: Equatable {
    enum Emphasis: Equatable {
        case normal
        case completed
        case failed
        case unavailable
    }

    static let stableTitle = "Skip Promos & Ads"

    let title: String
    let statusText: String
    let isEnabled: Bool
    let emphasis: Emphasis
    let phase: EpisodeAdFreePassPresentationPhase

    init(presentation: EpisodeAdFreePassPresentation) {
        title = switch presentation.phase {
        case .queued, .checking, .running:
            Self.stableTitle
        case .idle, .deferred, .completed, .failed, .unavailable:
            presentation.primaryActionTitle
        }
        statusText = presentation.statusText
        isEnabled = presentation.isPrimaryActionEnabled
        phase = presentation.phase

        emphasis = switch presentation.phase {
        case .failed:
            .failed
        case .completed:
            .completed
        case .unavailable:
            .unavailable
        case .idle, .queued, .deferred, .checking, .running:
            .normal
        }
    }
}
