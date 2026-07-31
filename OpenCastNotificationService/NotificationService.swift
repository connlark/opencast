import Foundation
import OSLog
import UserNotifications

// UNNotificationServiceExtension is Objective-C managed. The mutable state that
// crosses system timeout and URLSession callbacks is guarded by stateLock.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private static let maxArtworkBytes = 10 * 1024 * 1024
    private static let artworkLogger = Logger(
        subsystem: "com.connor.opencast",
        category: "NotificationServiceArtwork"
    )

    private let stateLock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var downloadTasks: [URLSessionDownloadTask] = []
    private var artworkAccumulator: ArtworkDownloadAccumulator?
    private var didDeliver = false

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }

        storePending(content: content, contentHandler: contentHandler)

        let artworkRequests = Self.artworkRequests(from: request.content.userInfo)
        Self.artworkLogger.notice(
            "Received notification with \(artworkRequests.count, privacy: .public) artwork request(s)."
        )
        guard !artworkRequests.isEmpty else {
            deliverPendingContent(attachments: [])
            return
        }

        fetchArtworkAttachments(for: artworkRequests)
    }

    override func serviceExtensionTimeWillExpire() {
        cancelDownloads()
        deliverPendingContent(attachments: finishActiveArtworkDownloads())
    }

    private func storePending(
        content: UNMutableNotificationContent,
        contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        stateLock.lock()
        self.contentHandler = contentHandler
        bestAttemptContent = content
        artworkAccumulator = nil
        didDeliver = false
        stateLock.unlock()
    }

    private func fetchArtworkAttachments(for artworkRequests: [ArtworkDownloadRequest]) {
        let accumulator = ArtworkDownloadAccumulator(artworkRequests: artworkRequests)
        guard storeArtworkAccumulator(accumulator) else {
            return
        }

        for artworkRequest in artworkRequests {
            fetchArtworkAttachment(for: artworkRequest) { [weak self] attachment in
                Self.artworkLogger.notice(
                    "Artwork request completed; attachment created: \(attachment != nil, privacy: .public)."
                )
                guard let attachments = accumulator.complete(
                    identifier: artworkRequest.identifier,
                    attachment: attachment
                ) else {
                    return
                }
                self?.deliverPendingContent(attachments: attachments)
            }
        }
    }

    private func fetchArtworkAttachment(
        for artworkRequest: ArtworkDownloadRequest,
        completion: @escaping @Sendable (UNNotificationAttachment?) -> Void
    ) {
        var request = URLRequest(
            url: artworkRequest.url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20
        )
        request.setValue(
            "image/jpeg,image/png,image/gif,image/heic,image/heif,image/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )

        let task = URLSession.shared.downloadTask(with: request) { [weak self] temporaryURL, response, error in
            guard error == nil,
                  let temporaryURL,
                  let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode)
            else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                Self.artworkLogger.error(
                    """
                    Artwork download failed; HTTP status: \(statusCode, privacy: .public), \
                    URL session error present: \(error != nil, privacy: .public).
                    """
                )
                completion(nil)
                return
            }

            completion(self?.attachment(
                from: temporaryURL,
                response: httpResponse,
                sourceURL: artworkRequest.url,
                identifier: artworkRequest.identifier
            ))
        }
        storeDownloadTask(task)
        task.resume()
    }

    private func attachment(
        from temporaryURL: URL,
        response: URLResponse,
        sourceURL: URL,
        identifier: String
    ) -> UNNotificationAttachment? {
        NotificationAttachmentFactory.attachment(
            from: temporaryURL,
            response: response,
            sourceURL: sourceURL,
            identifier: identifier,
            maxArtworkBytes: Self.maxArtworkBytes
        )
    }

    private func storeArtworkAccumulator(_ accumulator: ArtworkDownloadAccumulator) -> Bool {
        stateLock.lock()
        guard !didDeliver else {
            stateLock.unlock()
            return false
        }
        artworkAccumulator = accumulator
        stateLock.unlock()
        return true
    }

    private func storeDownloadTask(_ task: URLSessionDownloadTask) {
        stateLock.lock()
        if didDeliver {
            stateLock.unlock()
            task.cancel()
            return
        }
        downloadTasks.append(task)
        stateLock.unlock()
    }

    private func cancelDownloads() {
        stateLock.lock()
        let tasks = downloadTasks
        downloadTasks.removeAll()
        stateLock.unlock()
        tasks.forEach { $0.cancel() }
    }

    private func finishActiveArtworkDownloads() -> [UNNotificationAttachment] {
        stateLock.lock()
        let accumulator = artworkAccumulator
        stateLock.unlock()
        return accumulator?.finish() ?? []
    }

    private func deliverPendingContent(attachments: [UNNotificationAttachment]) {
        Self.artworkLogger.notice(
            "Delivering notification with \(attachments.count, privacy: .public) artwork attachment(s)."
        )
        stateLock.lock()
        guard !didDeliver, let content = bestAttemptContent else {
            stateLock.unlock()
            return
        }

        if !attachments.isEmpty {
            content.attachments = attachments
        }
        didDeliver = true
        let handler = contentHandler
        contentHandler = nil
        bestAttemptContent = nil
        artworkAccumulator = nil
        let tasks = downloadTasks
        downloadTasks.removeAll()
        stateLock.unlock()

        tasks.forEach { $0.cancel() }
        handler?(content)
    }

    private static func artworkRequests(from userInfo: [AnyHashable: Any]) -> [ArtworkDownloadRequest] {
        var requests = [ArtworkDownloadRequest]()
        if let artworkURL = NotificationPayload.artworkURL(from: userInfo) {
            requests.append(ArtworkDownloadRequest(
                url: artworkURL,
                identifier: NotificationArtworkAttachmentIdentifier.podcast
            ))
        }
        if let episodeArtworkURL = NotificationPayload.episodeArtworkURL(from: userInfo) {
            requests.append(ArtworkDownloadRequest(
                url: episodeArtworkURL,
                identifier: NotificationArtworkAttachmentIdentifier.episode
            ))
        }
        return requests
    }
}
