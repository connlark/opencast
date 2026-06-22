import Foundation
import UserNotifications

struct NotificationAuthorizationService {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws -> UNAuthorizationStatus {
        _ = try await UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        )
        return await authorizationStatus()
    }

    nonisolated static func allowsRemoteRegistration(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            true
        case .denied, .notDetermined:
            false
        @unknown default:
            false
        }
    }

    nonisolated static func label(for status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            "Not Determined"
        case .denied:
            "Denied"
        case .authorized:
            "Authorized"
        case .provisional:
            "Provisional"
        case .ephemeral:
            "Ephemeral"
        @unknown default:
            "Unknown"
        }
    }

    nonisolated static func permissionUnavailableMessage(for status: UNAuthorizationStatus) -> String {
        "Notification permission is \(label(for: status).lowercased())."
    }
}
