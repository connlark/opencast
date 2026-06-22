import Foundation

protocol NotificationSubscriptionSyncServicing {
    func sync(activePodcastIDs: Set<String>) async throws -> NotificationSubscriptionSyncResponse
    func syncIfRegistered(activePodcastIDs: Set<String>) async throws -> NotificationSubscriptionSyncResponse?
    func deleteInstallIfRegistered() async throws
}

extension NotificationSubscriptionSyncService: NotificationSubscriptionSyncServicing {}
