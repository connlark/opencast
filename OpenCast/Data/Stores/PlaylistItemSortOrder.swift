import Foundation

nonisolated enum PlaylistItemSortOrder: String, Equatable, Sendable, CaseIterable {
    case oldestFirst
    case newestFirst

    var title: String {
        switch self {
        case .oldestFirst:
            "Oldest First"
        case .newestFirst:
            "Newest First"
        }
    }

    func sorted<Element>(_ elements: [Element], date: (Element) -> Date?) -> [Element] {
        let keyed = elements.enumerated().map {
            (position: $0.offset, date: date($0.element), element: $0.element)
        }
        return keyed
            .sorted { lhs, rhs in
                switch (lhs.date, rhs.date) {
                case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
                    self == .oldestFirst ? lhsDate < rhsDate : lhsDate > rhsDate
                case (.some, .none):
                    true
                case (.none, .some):
                    false
                case (.some, .some), (.none, .none):
                    lhs.position < rhs.position
                }
            }
            .map { $0.element }
    }
}
