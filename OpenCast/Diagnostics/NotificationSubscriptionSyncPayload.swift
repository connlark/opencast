import Foundation

nonisolated struct NotificationSubscriptionSyncPayload: Encodable, Sendable {
    let subscriptions: [NotificationSubscriptionSyncItem]
}
