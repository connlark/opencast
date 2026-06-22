#if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
import Foundation

nonisolated struct NotificationPollSubscriptionsResponse: Decodable, Sendable {
    let message: String
    let feedsPolled: Int
    let feedsChanged: Int
    let notificationsAttempted: Int
    let apns200Count: Int
    let dedupedCount: Int
    let firstError: String?

    enum CodingKeys: String, CodingKey {
        case message
        case feedsPolled = "feeds_polled"
        case feedsChanged = "feeds_changed"
        case notificationsAttempted = "notifications_attempted"
        case apns200Count = "apns_200_count"
        case dedupedCount = "deduped_count"
        case firstError = "first_error"
    }
}
#endif
