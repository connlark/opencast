#if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
import Foundation

nonisolated enum NotificationRegistrationDiagnosticError: LocalizedError {
    case missingRegisteredCredential

    var errorDescription: String? {
        "No existing notification credential. Enable New Episode Notifications first."
    }
}
#endif
