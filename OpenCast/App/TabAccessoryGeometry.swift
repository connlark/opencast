import SwiftUI

/// The tab view's bottom accessory as the screens beneath it see it. The
/// accessory reports its placement and frame from inside the accessory
/// closure, the only place the system exposes them
/// (`TabAccessoryGeometryReader`); the tab root publishes the result through
/// the environment (`TabAccessoryGeometryStore`); each scroll view derives
/// its own bottom clearance from it (`TabAccessoryBottomClearance`). Frames are in the global space and always
/// measured: no state carries an assumed size.
nonisolated enum TabAccessoryGeometry: Equatable, Sendable {
    /// The tab root shows no accessory.
    case absent
    /// An accessory is shown, but the system reports no placement for it.
    /// Treated as expanded until a placement arrives: the clearance comes
    /// from the measured frame, as an expanded accessory's does.
    case undefined(frame: CGRect?)
    case inline(frame: CGRect?)
    case expanded(frame: CGRect?)

    /// A shown accessory. A frame with no positive, finite area (the first
    /// layout reports 0×0) is not a measurement yet.
    init(placement: TabViewBottomAccessoryPlacement?, frame: CGRect?) {
        let measured = frame.flatMap { Self.isMeasured($0) ? $0 : nil }
        guard let placement else {
            self = .undefined(frame: measured)
            return
        }
        switch placement {
        case .inline:
            self = .inline(frame: measured)
        case .expanded:
            self = .expanded(frame: measured)
        @unknown default:
            self = .undefined(frame: measured)
        }
    }

    var frame: CGRect? {
        switch self {
        case .absent:
            nil
        case .undefined(let frame), .inline(let frame), .expanded(let frame):
            frame
        }
    }

    /// The bottom content margin a scroll view needs so its last row rests
    /// one row gap above the accessory: the depth to which the accessory's
    /// measured frame reaches into the scroll view's frame, plus the
    /// consumer's own row spacing (RULING 13). SwiftUI lays a scroll view out
    /// inside the safe area, so its frame already stops at the system's own
    /// bottom inset (the bar, the home indicator and the part of the
    /// accessory the system insets for): the depth is signed, and where the
    /// system already leaves a gap below that edge only the rest of the row
    /// gap is added, so neither the inset nor the gap is counted twice.
    /// Beside a rail, where the accessory floats over the content column, the
    /// same depth is measured. No accessory, no margin.
    func bottomClearance(over viewport: CGRect?, rowSpacing: Double) -> Double {
        guard let frame, let viewport, Self.isMeasured(viewport),
              frame.minX < viewport.maxX, frame.maxX > viewport.minX,
              frame.maxY > viewport.minY
        else {
            return 0
        }
        let clearance = viewport.maxY - frame.minY + rowSpacing
        guard clearance > 0 else {
            return 0
        }
        return min(clearance.rounded(.up), viewport.height)
    }

    private static func isMeasured(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite
            && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.size.width > 0 && rect.size.height > 0
    }
}
