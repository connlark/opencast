import Foundation
import UserNotifications

final class ArtworkDownloadAccumulator: @unchecked Sendable {
    private let stateLock = NSLock()
    private let artworkRequests: [ArtworkDownloadRequest]
    private var pendingIdentifiers: Set<String>
    private var attachmentsByIdentifier = [String: UNNotificationAttachment]()
    private var finishedAttachments: [UNNotificationAttachment]?

    init(artworkRequests: [ArtworkDownloadRequest]) {
        precondition(!artworkRequests.isEmpty)
        let identifiers = Set(artworkRequests.map(\.identifier))
        precondition(identifiers.count == artworkRequests.count)
        self.artworkRequests = artworkRequests
        pendingIdentifiers = identifiers
    }

    func complete(identifier: String, attachment: UNNotificationAttachment?) -> [UNNotificationAttachment]? {
        stateLock.lock()
        guard finishedAttachments == nil,
              pendingIdentifiers.remove(identifier) != nil
        else {
            stateLock.unlock()
            return nil
        }

        if let attachment {
            attachmentsByIdentifier[identifier] = attachment
        }
        guard pendingIdentifiers.isEmpty else {
            stateLock.unlock()
            return nil
        }

        let attachments = finishLocked()
        stateLock.unlock()

        return attachments
    }

    func finish() -> [UNNotificationAttachment] {
        stateLock.lock()
        let attachments = finishLocked()
        stateLock.unlock()
        return attachments
    }

    private func finishLocked() -> [UNNotificationAttachment] {
        if let finishedAttachments {
            return finishedAttachments
        }

        pendingIdentifiers.removeAll()
        let attachments = artworkRequests.compactMap { attachmentsByIdentifier[$0.identifier] }
        finishedAttachments = attachments
        return attachments
    }
}
