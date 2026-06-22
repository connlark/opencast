import Foundation

enum RemoteNotificationRegistrationError: Error, LocalizedError {
    case deliveryTimedOut
    case timedOut

    var errorDescription: String? {
        switch self {
        case .deliveryTimedOut:
            "Diagnostic notification delivery timed out."
        case .timedOut:
            "APNs registration timed out."
        }
    }
}
