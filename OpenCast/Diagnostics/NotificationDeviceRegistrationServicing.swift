import UserNotifications

protocol NotificationDeviceRegistrationServicing {
    /// Always asks APNs for the current token. A token the backend already accepted is
    /// uploaded again only when `uploadsUnchangedToken` is set.
    func registerCurrentDevice(uploadsUnchangedToken: Bool) async throws -> UNAuthorizationStatus
    func unregisterCurrentDeviceIfPossible() async throws
    func clearLocalDeviceToken()
}

extension NotificationRegistrationService: NotificationDeviceRegistrationServicing {}
