import Foundation

struct ImportedSubscriptionsNotification: Equatable, Identifiable, Sendable {
    let id: Int
    let feedCount: Int

    var title: String {
        "\(feedCount) \(feedCount == 1 ? "feed" : "feeds") auto imported"
    }

    var detail: String {
        "Your iCloud subscriptions are ready."
    }
}
