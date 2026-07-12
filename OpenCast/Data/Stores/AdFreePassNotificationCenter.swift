import UserNotifications

protocol AdFreePassNotificationCenter {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestProvisionalAuthorization() async
    func add(_ request: UNNotificationRequest) async throws
}

extension UNUserNotificationCenter: AdFreePassNotificationCenter {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await notificationSettings().authorizationStatus
    }

    func requestProvisionalAuthorization() async {
        _ = try? await NotificationAuthorizationService().requestProvisionalAuthorization()
    }
}
