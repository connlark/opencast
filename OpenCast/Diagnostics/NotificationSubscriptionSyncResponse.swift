import Foundation

nonisolated struct NotificationSubscriptionSyncResponse: Decodable, Sendable {
    let message: String
    let accepted: [NotificationSubscriptionSyncAccepted]
    let rejected: [NotificationSubscriptionSyncRejected]
    let pending: [NotificationSubscriptionSyncPending]

    init(
        message: String,
        accepted: [NotificationSubscriptionSyncAccepted],
        rejected: [NotificationSubscriptionSyncRejected],
        pending: [NotificationSubscriptionSyncPending] = []
    ) {
        self.message = message
        self.accepted = accepted
        self.rejected = rejected
        self.pending = pending
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decode(String.self, forKey: .message)
        accepted = try container.decode(
            [NotificationSubscriptionSyncAccepted].self,
            forKey: .accepted
        )
        rejected = try container.decode(
            [NotificationSubscriptionSyncRejected].self,
            forKey: .rejected
        )
        // Older servers omit the pending lane.
        pending = try container.decodeIfPresent(
            [NotificationSubscriptionSyncPending].self,
            forKey: .pending
        ) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case message
        case accepted
        case rejected
        case pending
    }
}
