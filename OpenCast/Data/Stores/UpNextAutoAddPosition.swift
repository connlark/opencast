/// Where Auto Add to Up Next puts a show's new episodes. The raw value is
/// the picker's identity; the synced record stores Pocket Casts' numbers
/// (`SubscriptionRecord.autoAddToUpNext`), and only this type knows them.
nonisolated enum UpNextAutoAddPosition: String, CaseIterable, Identifiable, Sendable {
    case top
    case bottom

    /// 1 is bottom and 2 is top; anything else, 0 included, is off.
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

    /// The stored value for a show's position, where off is 0.
    static func stored(_ position: UpNextAutoAddPosition?) -> Int {
        position?.stored ?? 0
    }

    /// The furthest-forward position among stored values, top over bottom
    /// over off, stored again, so twin records merge to the same value in
    /// any order.
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
