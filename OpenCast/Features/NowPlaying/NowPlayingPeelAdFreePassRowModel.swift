/// Pure mapping from the ad-free pass presentation to the fixed-footprint
/// Sound Lab row: an actionable title (Skip, Resume, Retry, Reanalyze —
/// never progress text or "Working"), with live status carried only by the
/// trailing glyph and the accessibility value.
nonisolated struct NowPlayingPeelAdFreePassRowModel: Equatable {
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
    let trailingSystemImage: String

    init(presentation: EpisodeAdFreePassPresentation) {
        title = presentation.isPrimaryActionEnabled
            ? presentation.primaryActionTitle
            : Self.stableTitle
        statusText = presentation.statusText
        isEnabled = presentation.isPrimaryActionEnabled

        emphasis = switch presentation.stage {
        case .failed:
            .failed
        case .completed:
            .completed
        case .unavailable:
            .unavailable
        default:
            .normal
        }

        trailingSystemImage = switch presentation.stage {
        case .downloadingEpisode, .installingModel, .installingSpeechAssets, .transcribing, .analyzing:
            "hourglass"
        case .completed:
            "checkmark.circle.fill"
        case .failed, .interrupted:
            "arrow.clockwise"
        default:
            "chevron.right"
        }
    }
}
