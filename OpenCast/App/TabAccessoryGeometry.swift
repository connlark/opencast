import SwiftUI

/// Frames are in the global space and always measured: no state carries an
/// assumed size.
nonisolated enum TabAccessoryGeometry: Equatable, Sendable {
    case absent
    /// Shown with no placement reported; treated as expanded until one arrives.
    case undefined(frame: CGRect?)
    case inline(frame: CGRect?)
    case expanded(frame: CGRect?)

    /// A frame with no positive, finite area (the first layout reports 0×0)
    /// is not a measurement yet.
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

    /// The accessory's signed depth into the scroll view's frame plus one row
    /// gap. That frame already stops at the system's bottom inset, so where the
    /// system leaves a gap only the rest of the row gap is added.
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
