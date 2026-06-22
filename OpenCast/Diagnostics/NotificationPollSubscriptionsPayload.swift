#if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
import Foundation

nonisolated struct NotificationPollSubscriptionsPayload: Encodable, Sendable {
    let feedURL: String?

    enum CodingKeys: String, CodingKey {
        case feedURL = "feed_url"
    }
}
#endif
