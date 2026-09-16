import Foundation

struct ImportedSubscriptionsNotification: Equatable, Identifiable, Sendable {
    let id: Int
    let feedURLStrings: Set<String>

    var feedCount: Int { feedURLStrings.count }

    func merging(feedURLStrings: Set<String>) -> Self {
        Self(id: id, feedURLStrings: self.feedURLStrings.union(feedURLStrings))
    }

    var title: String {
        "\(feedCount) \(feedCount == 1 ? "subscription" : "subscriptions") restored"
    }

    var detail: String {
        "Your shows are back. Episodes load as their feeds are fetched."
    }
}
