#if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
import Foundation

struct NotificationSecurityDiagnosticResult {
    let appAttestStatus: String
    let rejectedProofMessage: String
    let validProofMessage: String
    let detail: String
}
#endif
