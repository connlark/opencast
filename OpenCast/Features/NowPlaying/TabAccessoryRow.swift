import OSLog
import SwiftUI

/// Each row's fixed width, all but its title and scrubber: dense 146 pt, standard 176 pt, wide 236 pt.
nonisolated enum TabAccessoryRow: Equatable, Sendable {
    case dense
    case standard
    case wide

    /// The title floor is what the dense row leaves its title in the narrowest accessory, the iPhone
    /// Duo's Closed capsule: 290 − 146 = 144. Below this width the standard row would leave its
    /// title under the floor: W − 176 < 144.
    static let denseThreshold: Double = 320

    /// One point of travel per 15 s default skip through a 60-minute episode (3600 / 15), so the
    /// scrubber is no coarser than the skip button beside it.
    static let scrubberWidth: Double = 240

    /// The wide row's fixed parts, title floor and scrubber: 236 + 144 + 240.
    static let wideThreshold: Double = 620

    init(expandedWidth width: Double?) {
        guard let width else {
            self = .standard
            return
        }
        if width < Self.denseThreshold {
            self = .dense
        } else if width >= Self.wideThreshold {
            self = .wide
        } else {
            self = .standard
        }
    }

    /// On re-expansion an expanded report can briefly carry the previous inline frame and pick a
    /// narrower row; no filter can tell it from a capsule that narrow, so none is attempted.
    init(geometry: TabAccessoryGeometry, isInline: Bool) {
        self.init(expandedWidth: isInline ? nil : Self.expandedWidth(of: geometry))
    }

    static func expandedWidth(of geometry: TabAccessoryGeometry) -> Double? {
        switch geometry {
        case .expanded(let frame), .undefined(let frame):
            frame.map { Double($0.width) }
        case .inline, .absent:
            nil
        }
    }

    var metrics: Metrics {
        switch self {
        case .dense:
            Metrics(
                horizontalPadding: 8,
                verticalPadding: 0,
                artworkSide: 30,
                artworkTitleSpacing: 8,
                controlSpacing: 2,
                controlCount: 2,
                hasScrubber: false
            )
        case .standard:
            Metrics(
                horizontalPadding: 12,
                verticalPadding: 6,
                artworkSide: 38,
                artworkTitleSpacing: 10,
                controlSpacing: 8,
                controlCount: 2,
                hasScrubber: false
            )
        case .wide:
            Metrics(
                horizontalPadding: 12,
                verticalPadding: 0,
                artworkSide: 38,
                artworkTitleSpacing: 10,
                controlSpacing: 8,
                controlCount: 3,
                hasScrubber: true
            )
        }
    }

    struct Metrics: Equatable, Sendable {
        let horizontalPadding: Double
        let verticalPadding: Double
        let artworkSide: Double
        let artworkTitleSpacing: Double
        let controlSpacing: Double
        let controlCount: Int
        let hasScrubber: Bool
    }

    private static let logger = Logger(subsystem: "com.connor.opencast", category: "TabAccessoryRow")

    static func log(accessory: String, geometry: TabAccessoryGeometry, isInline: Bool) {
        let row = TabAccessoryRow(geometry: geometry, isInline: isInline)
        let width = geometry.frame.map { "\(Double($0.width))" } ?? "none"
        logger.info(
            "\(accessory, privacy: .public) row=\(String(describing: row), privacy: .public) width=\(width, privacy: .public) report=\(String(describing: geometry), privacy: .public) inline=\(isInline, privacy: .public)"
        )
    }
}

extension View {
    /// Its widths are constants no row can change, so the measurement that picks the row cannot
    /// move with the row it picked. The ideal width is the narrowest standard row.
    func tabAccessoryRowContainer() -> some View {
        frame(minWidth: 0, idealWidth: TabAccessoryRow.denseThreshold, maxWidth: .infinity)
    }
}
