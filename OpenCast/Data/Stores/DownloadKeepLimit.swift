/// How many completed downloads a show keeps. The raw value is a stored
/// preference value, so case raw values are durable storage keys. A show's
/// own choice is a `DownloadKeepLimit?`, where nil follows the default.
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

    /// "No Limit", "1 Episode", "3 Episodes".
    var title: String {
        guard let maximumCount else {
            return "No Limit"
        }
        return maximumCount == 1 ? "1 Episode" : "\(maximumCount) Episodes"
    }

    /// "No limit", "Keep 3".
    var shortTitle: String {
        guard let maximumCount else {
            return "No limit"
        }
        return "Keep \(maximumCount)"
    }
}
