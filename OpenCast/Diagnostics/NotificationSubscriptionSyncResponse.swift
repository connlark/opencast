import Foundation

nonisolated struct NotificationSubscriptionSyncResponse: Decodable, Sendable {
    let message: String
    let accepted: [NotificationSubscriptionSyncAccepted]
    let rejected: [NotificationSubscriptionSyncRejected]
}
