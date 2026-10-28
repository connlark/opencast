/// How many episodes Up Next may hold before Auto Add to Up Next stops
/// adding (or, under Only Add to Top, replaces the last row). It counts the
/// whole queue, hand-queued rows included. The raw value is the stored
/// preference value.
nonisolated enum UpNextAutoAddLimit: Int, CaseIterable, Identifiable, Sendable {
    case ten = 10
    case twenty = 20
    case fifty = 50
    case oneHundred = 100
    case twoHundred = 200
    case fiveHundred = 500
    case oneThousand = 1000

    static let standard = UpNextAutoAddLimit.oneHundred

    var id: Int {
        rawValue
    }

    /// Grouped as the rule sentence groups it ("1,000 Episodes").
    var title: String {
        "\(rawValue.formatted()) Episodes"
    }
}
