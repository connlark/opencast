import OSLog
import SwiftUI
import Synchronization

/// Derived on every layout from the window's size class and current regions,
/// never from orientation, idiom or the screen, and never cached.
nonisolated enum WindowPose: Equatable, Sendable {
    case compact
    case regularFlat
    /// Book. The band is in the reading proxy's space.
    case foldedVertical(band: CGRect)
    /// Laptop. The band is in the reading proxy's space.
    case foldedHorizontal(band: CGRect)

    private static let logger = Logger(subsystem: "com.connor.opencast", category: "WindowPose")
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

    /// More than one usable `.division` region has never been seen on the Duo;
    /// the log records which one placed the layout.
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
