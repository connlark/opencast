/// Pure mapping from the ad-free pass presentation to the fixed-footprint
/// Sound Lab row: an actionable title (Skip, Resume, Retry, Reanalyze —
/// never progress text or "Working"), with live status carried only by the
/// trailing glyph and the accessibility value.
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
