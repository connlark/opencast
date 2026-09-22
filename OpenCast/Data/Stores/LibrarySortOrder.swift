import Foundation

enum LibrarySortOrder: String, CaseIterable, Identifiable, Sendable {
    case title
    case recentEpisodes

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .title:
            "Title"
        case .recentEpisodes:
            "Recent Episodes"
        }
    }

    /// Title keeps the store's order (already title, then feed URL). Recent
    /// Episodes puts the newest released episode first and undated shows
    /// last, breaking ties by title and then feed URL. Played state plays no
    /// part, so listening never reorders the Library.
    func sorted(
        _ subscriptions: [SubscriptionRecord],
        latestReleaseDate: (String) -> Date?
    ) -> [SubscriptionRecord] {
        switch self {
        case .title:
            return subscriptions
        case .recentEpisodes:
            let dated = subscriptions.map { (subscription: $0, releasedAt: latestReleaseDate($0.feedURL)) }
            return dated
                .sorted { lhs, rhs in
                    switch (lhs.releasedAt, rhs.releasedAt) {
                    case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
                        return lhsDate > rhsDate
                    case (.some, nil):
                        return true
                    case (nil, .some):
                        return false
                    default:
                        let titleOrder = lhs.subscription.title.localizedStandardCompare(rhs.subscription.title)
                        guard titleOrder == .orderedSame else {
                            return titleOrder == .orderedAscending
                        }
                        return lhs.subscription.feedURL < rhs.subscription.feedURL
                    }
                }
                .map(\.subscription)
        }
    }
}
