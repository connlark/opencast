import CoreGraphics

/// How Now Playing arranges the player and its secondary pane, resolved on
/// every layout from exactly the window's pose, the window's size and
/// whether the scene has reported a fold. The decision table is total:
///
/// | Pose | Scene | Window | Arrangement |
/// | --- | --- | --- | --- |
/// | `compact` | any | any | `card` |
/// | `foldedVertical(band:)` | any (the band is a fold report) | any | `split(band:)` |
/// | `foldedHorizontal(band:)` | any (the band is a fold report) | any | `single(band:)` |
/// | `regularFlat` | foldable | wider than tall | `split(band: nil)` |
/// | `regularFlat` | foldable | square or taller than wide | `single(band: nil)` |
/// | `regularFlat` | not foldable | any | `card` |
///
/// Compact always wins. Derive it on every layout, never from the hinge,
/// orientation, idiom or the screen, and never cache it from an earlier one.
nonisolated enum NowPlayingArrangement: Equatable, Sendable {
    /// Today's card: every compact window, and every regular window whose
    /// scene has never reported a fold.
    case card
    /// The player beside the secondary pane on a wide display: the player on
    /// the band's leading side and the pane on its trailing side when folded,
    /// a plain split when flat. The band is in the window reader's space.
    case split(band: CGRect?)
    /// One card on a tall display, the pane collapsed to its row: when
    /// folded, the media above the band and the controls below it. The band
    /// is in the window reader's space.
    case single(band: CGRect?)

    init(pose: WindowPose, windowSize: CGSize, isFoldableScene: Bool) {
        switch pose {
        case .compact:
            self = .card
        case .foldedVertical(let band):
            self = .split(band: band)
        case .foldedHorizontal(let band):
            self = .single(band: band)
        case .regularFlat:
            guard isFoldableScene else {
                self = .card
                return
            }
            self = windowSize.width > windowSize.height ? .split(band: nil) : .single(band: nil)
        }
    }

    /// The scene flag as it stands on this layout: the scene's latch, or a
    /// `.division` region in the regions this layout reads (active or not),
    /// so the flag is updated before the arrangement is resolved.
    static func isFoldableScene(latched: Bool, currentRegions: [WindowDivisionRegion]) -> Bool {
        latched || SceneLibraryLayouts.reportsFold(currentRegions)
    }

    /// The fold band, in the window reader's space.
    var band: CGRect? {
        switch self {
        case .card:
            nil
        case .split(let band), .single(let band):
            band
        }
    }

    /// Foldable arrangements lay out across the whole window, inside its safe
    /// rectangle; the card keeps today's surface.
    var usesWindowSizedSurface: Bool {
        self != .card
    }

    var paneStyle: NowPlayingSecondaryPaneStyle {
        switch self {
        case .card:
            .entryPointsOnly
        case .split:
            .beside
        case .single:
            .disclosure
        }
    }
}
