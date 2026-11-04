import OSLog
import SwiftUI

/// Which row the tab accessory draws, resolved from the accessory's own
/// measured width: the frame `TabAccessoryGeometryReader` reports from inside
/// the accessory closure and the tab root publishes through
/// `TabAccessoryGeometryStore`. Nothing else is measured, and the row never
/// feeds back into that width: the measured element is the invariant wrapper
/// (`tabAccessoryRowContainer()`), which takes the width the system proposes
/// whatever row it holds. The row is recomputed on every report, with exact
/// thresholds and no hysteresis; before the first report it is `standard`.
///
/// The thresholds come from each row's fixed horizontal parts (padding,
/// artwork, gaps and 44 pt controls; `Metrics.fixedWidth`): dense 146 pt,
/// standard 176 pt, wide 236 pt plus its scrubber.
nonisolated enum TabAccessoryRow: Equatable, Sendable {
    /// A one-line title beside smaller artwork, for a narrow capsule.
    case dense
    /// The title over the show name, play / pause and skip forward.
    case standard
    /// The standard row with a scrubber and skip back between the title and
    /// the transport, for a wide capsule.
    case wide

    /// The least room a row's title gets: what the dense row leaves its title
    /// in the narrowest accessory measured, the iPhone Duo's Closed capsule
    /// (290 pt): 290 − 146 = 144.
    static let titleFloor: Double = 144

    /// Below this width today's row would give its title less than the dense
    /// title's floor (W − 176 < 144 ⇔ W < 320), so the dense row takes over.
    static let denseThreshold: Double = 320

    /// The width at which one point of the scrubber's travel is one default
    /// skip forward (15 s, `PlaybackSkipIntervalOption.defaultForward`)
    /// through a 60-minute episode (3600 / 15), so the scrubber is never
    /// coarser than the skip button beside it. The 60 minutes is a typical
    /// episode length, an inference rather than a measurement.
    static let scrubberWidth: Double = 240

    /// The wide row's fixed parts, its title floor and its scrubber:
    /// 236 + 144 + 240 = 620. At or above it the wide row fits with nothing
    /// truncating below the floor.
    static let wideThreshold: Double = 620

    /// The tap area of every control in the row.
    static let controlSide: Double = 44

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

    /// The row for the accessory's published geometry. The inline
    /// (minimized) accessory keeps today's inline layout, which is the
    /// standard row's, whatever its width; so does an accessory that has not
    /// reported yet. A report made while the accessory was inline does not
    /// describe the expanded capsule, so it is not used for an expanded row.
    /// On re-expansion an expanded report has been seen to carry the
    /// previous inline frame briefly, picking a narrower row until the next
    /// frame report replaces it. No filter here can tell that report from a
    /// capsule that really is that narrow, so none is attempted.
    init(geometry: TabAccessoryGeometry, isInline: Bool) {
        self.init(expandedWidth: isInline ? nil : Self.expandedWidth(of: geometry))
    }

    /// The width an expanded accessory reported; an accessory with no
    /// placement yet is treated as expanded (`TabAccessoryGeometry.undefined`).
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

    /// One row's expanded geometry. The inline accessory keeps its own.
    struct Metrics: Equatable, Sendable {
        let horizontalPadding: Double
        let verticalPadding: Double
        let artworkSide: Double
        let artworkTitleSpacing: Double
        /// The gap between the title button and each control after it.
        let controlSpacing: Double
        /// The 44 pt controls after the title: play / pause and skip forward,
        /// and skip back in the wide row.
        let controlCount: Int
        let hasScrubber: Bool

        /// Everything in the row but the title and the scrubber.
        var fixedWidth: Double {
            let gaps = controlCount + (hasScrubber ? 1 : 0)
            return 2 * horizontalPadding + artworkSide + artworkTitleSpacing
                + Double(gaps) * controlSpacing + Double(controlCount) * TabAccessoryRow.controlSide
        }
    }

    private static let logger = Logger(subsystem: "com.connor.opencast", category: "TabAccessoryRow")

    /// One line per accessory report, so a report sequence across a row
    /// change can be read back (`log stream --level info --predicate
    /// 'category == "TabAccessoryRow"'`).
    static func log(accessory: String, geometry: TabAccessoryGeometry, isInline: Bool) {
        let row = TabAccessoryRow(geometry: geometry, isInline: isInline)
        let width = geometry.frame.map { "\(Double($0.width))" } ?? "none"
        logger.info(
            "\(accessory, privacy: .public) row=\(String(describing: row), privacy: .public) width=\(width, privacy: .public) report=\(String(describing: geometry), privacy: .public) inline=\(isInline, privacy: .public)"
        )
    }
}

extension View {
    /// The accessory's measured element: it takes the width the system
    /// proposes whatever row it holds, and its minimum and ideal widths are
    /// constants no row can change, so the measurement that picks the row
    /// cannot move with the row it picked. Asked for its ideal size, it
    /// answers the narrowest width the standard row is drawn at.
    func tabAccessoryRowContainer() -> some View {
        frame(minWidth: 0, idealWidth: TabAccessoryRow.denseThreshold, maxWidth: .infinity)
    }
}
