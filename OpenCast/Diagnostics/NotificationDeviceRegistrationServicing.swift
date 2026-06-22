import UserNotifications

protocol NotificationDeviceRegistrationServicing {
    func registerCurrentDevice() async throws -> UNAuthorizationStatus
    func unregisterCurrentDeviceIfPossible() async throws
    func clearLocalDeviceToken()
}

extension NotificationRegistrationService: NotificationDeviceRegistrationServicing {}
