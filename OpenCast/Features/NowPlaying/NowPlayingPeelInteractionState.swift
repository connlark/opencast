import CoreGraphics

enum NowPlayingPeelInteractionState: Equatable {
    case closed
    case openingDrag
    case open
    case closingDrag
    case settling(targetOpen: Bool)

    var intendedOpen: Bool {
        switch self {
        case .open, .closingDrag:
            true
        case .settling(let targetOpen):
            targetOpen
        case .closed, .openingDrag:
            false
        }
    }

    var isTrackingDrag: Bool {
        switch self {
        case .openingDrag, .closingDrag:
            true
        case .closed, .open, .settling:
            false
        }
    }

    static func settled(open: Bool) -> NowPlayingPeelInteractionState {
        open ? .open : .closed
    }

    func settledIfNeeded(progress: CGFloat, tolerance: CGFloat = 0.002) -> NowPlayingPeelInteractionState? {
        guard case .settling(let targetOpen) = self else {
            return nil
        }

        let target: CGFloat = targetOpen ? 1 : 0
        guard abs(progress - target) < tolerance else {
            return nil
        }

        return .settled(open: targetOpen)
    }
}
