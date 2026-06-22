import UserNotifications

protocol NotificationAuthorizationProviding {
    func authorizationStatus() async -> UNAuthorizationStatus
}

extension NotificationAuthorizationService: NotificationAuthorizationProviding {}
