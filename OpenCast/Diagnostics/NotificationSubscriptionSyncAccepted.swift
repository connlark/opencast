import Foundation

nonisolated struct NotificationSubscriptionSyncAccepted: Decodable, Sendable {
    let feedURL: String
    let title: String?

    enum CodingKeys: String, CodingKey {
        case feedURL = "feed_url"
        case title
    }
}
