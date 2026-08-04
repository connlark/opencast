import Foundation

nonisolated struct NotificationSubscriptionSyncAccepted: Decodable, Sendable {
    let feedURL: String
    let title: String?
    /// Absent from older servers and for feeds that have never been polled.
    let health: NotificationFeedHealth?

    enum CodingKeys: String, CodingKey {
        case feedURL = "feed_url"
        case title
        case health
    }
}
