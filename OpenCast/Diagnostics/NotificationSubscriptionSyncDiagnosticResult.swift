#if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
import Foundation

nonisolated struct NotificationSubscriptionSyncDiagnosticResult: Sendable {
    let syncStatus: String
    let acceptedCount: Int
    let rejectedCount: Int
    let rejectedSummary: String
    let detail: String
}
#endif
