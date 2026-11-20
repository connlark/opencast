/// The raw value is the stored preference value.
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

    var title: String {
        "\(rawValue.formatted()) Episodes"
    }
}
