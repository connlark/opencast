import Foundation

nonisolated struct NotificationSubscriptionSyncItem: Encodable, Sendable {
    let feedURL: String
    let notificationsEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case feedURL = "feed_url"
        case notificationsEnabled = "notifications_enabled"
    }
}
