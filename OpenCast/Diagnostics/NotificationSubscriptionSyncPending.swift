import Foundation

nonisolated struct NotificationSubscriptionSyncPending: Decodable, Sendable {
    let feedURL: String

    enum CodingKeys: String, CodingKey {
        case feedURL = "feed_url"
    }
}
