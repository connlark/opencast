/// Raw values are stored preference values; never change them.
nonisolated enum DownloadKeepLimit: String, CaseIterable, Identifiable, Sendable {
    case noLimit
    case one = "1"
    case two = "2"
    case three = "3"
    case five = "5"
    case ten = "10"

    var id: String {
        rawValue
    }

    var maximumCount: Int? {
        switch self {
        case .noLimit:
            nil
        case .one:
            1
        case .two:
            2
        case .three:
            3
        case .five:
            5
        case .ten:
            10
        }
    }

    var title: String {
        guard let maximumCount else {
            return "No Limit"
        }
        return maximumCount == 1 ? "1 Episode" : "\(maximumCount) Episodes"
    }

    var shortTitle: String {
        guard let maximumCount else {
            return "No limit"
        }
        return "Keep \(maximumCount)"
    }
}
