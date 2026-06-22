#if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
import Foundation

nonisolated struct NotificationPollSubscriptionsDiagnosticResult: Sendable {
    let pollStatus: String
    let feedsPolled: Int
    let feedsChanged: Int
    let notificationsAttempted: Int
    let apns200Count: Int
    let dedupedCount: Int
    let firstError: String?
    let detail: String
}
#endif
