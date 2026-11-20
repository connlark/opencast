/// The synced record stores Pocket Casts' numbers (`SubscriptionRecord.autoAddToUpNext`), and
/// only this type knows them.
nonisolated enum UpNextAutoAddPosition: String, CaseIterable, Identifiable, Sendable {
    case top
    case bottom

    init?(stored: Int) {
        switch stored {
        case 1:
            self = .bottom
        case 2:
            self = .top
        default:
            return nil
        }
    }

    var stored: Int {
        switch self {
        case .bottom:
            1
        case .top:
            2
        }
    }

    static func stored(_ position: UpNextAutoAddPosition?) -> Int {
        position?.stored ?? 0
    }

    /// Order-independent, so twin records merge to the same value on every peer.
    static func merged(_ values: some Sequence<Int>) -> Int {
        stored(values.compactMap(UpNextAutoAddPosition.init(stored:)).max { $0.stored < $1.stored })
    }

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .top:
            "Top"
        case .bottom:
            "Bottom"
        }
    }
}
