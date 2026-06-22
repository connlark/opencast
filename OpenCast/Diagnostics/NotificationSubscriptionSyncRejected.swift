import Foundation

nonisolated struct NotificationSubscriptionSyncRejected: Decodable, Sendable {
    let feedURL: String
    let error: String

    enum CodingKeys: String, CodingKey {
        case feedURL = "feed_url"
        case error
    }
}
