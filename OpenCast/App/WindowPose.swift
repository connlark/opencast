import OSLog
import SwiftUI
import Synchronization

/// The window's pose, derived from what the window reports (its horizontal
/// size class and its active `.division` reserved region), never from
/// orientation, idiom or the screen. The decision table is total:
///
/// | Horizontal size class | Usable `.division` region | Pose |
/// | --- | --- | --- |
/// | `.compact` or nil | ignored | `compact` |
/// | `.regular` | none | `regularFlat` |
/// | `.regular` | taller than wide, or square | `foldedVertical(band:)` |
/// | `.regular` | wider than tall | `foldedHorizontal(band:)` |
///
/// Every row reads "any" for the vertical size class, so it is not an input.
/// Derive the pose on every layout from the current regions; it is a value,
/// never a cache of the first layout.
nonisolated enum WindowPose: Equatable, Sendable {
    /// The Duo's outer display, every compact iPhone, and the conservative
    /// fallback when the horizontal size class is unknown.
    case compact
    /// A regular-width window with no usable fold.
    case regularFlat
    /// Book: the band is taller than wide. In the reading proxy's space.
    case foldedVertical(band: CGRect)
    /// Laptop: the band is wider than tall. In the reading proxy's space.
    case foldedHorizontal(band: CGRect)

    private static let logger = Logger(subsystem: "com.connor.opencast", category: "WindowPose")
    /// The usable bands last logged as several, so the log fires once per
    /// change rather than on every layout pass that derives the pose.
    private static let lastLoggedFolds = Mutex<[CGRect]>([])

    init(horizontalSizeClass: UserInterfaceSizeClass?, divisionRegions: [WindowDivisionRegion]) {
        guard horizontalSizeClass == .regular else {
            self = .compact
            return
        }
        guard let band = Self.fold(in: divisionRegions)?.frame else {
            self = .regularFlat
            return
        }
        Self.logIfSeveralFolds(in: divisionRegions, winner: band)
        self = band.size.height >= band.size.width
            ? .foldedVertical(band: band)
            : .foldedHorizontal(band: band)
    }

    var band: CGRect? {
        switch self {
        case .compact, .regularFlat:
            nil
        case .foldedVertical(let band), .foldedHorizontal(let band):
            band
        }
    }

    /// The band in a consumer's local space, given the consumer's frame in
    /// the space the regions were read in.
    func band(inConsumerFrame consumerFrame: CGRect) -> CGRect? {
        band?.offsetBy(dx: -consumerFrame.minX, dy: -consumerFrame.minY)
    }

    /// The largest usable region by area; a tie keeps the earlier region.
    static func fold(in regions: [WindowDivisionRegion]) -> WindowDivisionRegion? {
        var winner: WindowDivisionRegion?
        for region in regions where region.isUsable {
            if let current = winner, region.area <= current.area {
                continue
            }
            winner = region
        }
        return winner
    }

    /// More than one usable `.division` region is UNKNOWN on the Duo; the log
    /// records which one placed the layout, once per distinct set.
    private static func logIfSeveralFolds(in regions: [WindowDivisionRegion], winner: CGRect) {
        let usable = regions.filter(\.isUsable).map(\.frame)
        guard usable.count > 1 else {
            return
        }
        let isNew = lastLoggedFolds.withLock { lastLogged in
            guard lastLogged != usable else {
                return false
            }
            lastLogged = usable
            return true
        }
        guard isNew else {
            return
        }
        let frames = usable.map { String(describing: $0) }.joined(separator: " ")
        logger.notice(
            "UNKNOWN: \(usable.count) active .division regions \(frames, privacy: .public); the largest by area wins: \(String(describing: winner), privacy: .public)"
        )
    }
}
