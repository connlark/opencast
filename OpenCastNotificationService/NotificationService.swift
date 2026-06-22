import Foundation
import UserNotifications

// UNNotificationServiceExtension is Objective-C managed. The mutable state that
// crosses system timeout and URLSession callbacks is guarded by stateLock.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private static let maxArtworkBytes = 10 * 1024 * 1024

    private let stateLock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var downloadTask: URLSessionDownloadTask?
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

        guard let artworkURL = Self.artworkURL(from: request.content.userInfo) else {
            deliverPendingContent(attachment: nil)
            return
        }

        fetchArtworkAttachment(from: artworkURL) { [weak self] attachment in
            self?.deliverPendingContent(attachment: attachment)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        cancelDownload()
        deliverPendingContent(attachment: nil)
    }

    private func storePending(
        content: UNMutableNotificationContent,
        contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        stateLock.lock()
        self.contentHandler = contentHandler
        bestAttemptContent = content
        didDeliver = false
        stateLock.unlock()
    }

    private func fetchArtworkAttachment(
        from url: URL,
        completion: @escaping @Sendable (UNNotificationAttachment?) -> Void
    ) {
        var request = URLRequest(
            url: url,
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
                completion(nil)
                return
            }

            completion(self?.attachment(from: temporaryURL, response: httpResponse, sourceURL: url))
        }
        storeDownloadTask(task)
        task.resume()
    }

    private func attachment(
        from temporaryURL: URL,
        response: URLResponse,
        sourceURL: URL
    ) -> UNNotificationAttachment? {
        NotificationAttachmentFactory.attachment(
            from: temporaryURL,
            response: response,
            sourceURL: sourceURL,
            maxArtworkBytes: Self.maxArtworkBytes
        )
    }

    private func storeDownloadTask(_ task: URLSessionDownloadTask) {
        stateLock.lock()
        if didDeliver {
            stateLock.unlock()
            task.cancel()
            return
        }
        downloadTask = task
        stateLock.unlock()
    }

    private func cancelDownload() {
        stateLock.lock()
        let task = downloadTask
        downloadTask = nil
        stateLock.unlock()
        task?.cancel()
    }

    private func deliverPendingContent(attachment: UNNotificationAttachment?) {
        stateLock.lock()
        guard !didDeliver, let content = bestAttemptContent else {
            stateLock.unlock()
            return
        }

        if let attachment {
            content.attachments = [attachment]
        }
        didDeliver = true
        let handler = contentHandler
        contentHandler = nil
        bestAttemptContent = nil
        let task = downloadTask
        downloadTask = nil
        stateLock.unlock()

        task?.cancel()
        handler?(content)
    }

    private static func artworkURL(from userInfo: [AnyHashable: Any]) -> URL? {
        NotificationPayload.artworkURL(from: userInfo)
    }
}
