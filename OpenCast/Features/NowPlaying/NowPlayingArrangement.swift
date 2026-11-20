import CoreGraphics

/// Derive this on every layout, never from the hinge, orientation, idiom or screen, and
/// never cache it from an earlier layout.
nonisolated enum NowPlayingArrangement: Equatable, Sendable {
    case card
    case split(band: CGRect?)
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

    /// Reads this layout's regions as well as the latch, so the flag is current before the
    /// arrangement is resolved.
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
