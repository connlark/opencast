#if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
import Foundation

nonisolated struct NotificationRegistrationDiagnosticResult: Sendable {
    let permissionStatus: String
    let apnsRegistrationStatus: String
    let workerRegistrationStatus: String
    let testPushStatus: String
    let apnsStatus: String
    let deviceDeliveryStatus: String
    let apnsError: String?
    let detail: String
}
#endif
