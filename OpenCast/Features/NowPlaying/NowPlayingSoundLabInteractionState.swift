enum NowPlayingSoundLabInteractionState: Equatable {
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

    static func settled(open: Bool) -> NowPlayingSoundLabInteractionState {
        open ? .open : .closed
    }
}
