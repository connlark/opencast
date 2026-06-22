import Foundation
import UserNotifications

enum NotificationAttachmentFactory {
    static func attachment(
        from temporaryURL: URL,
        response: URLResponse,
        sourceURL: URL,
        maxArtworkBytes: Int
    ) -> UNNotificationAttachment? {
        guard let fileSize = try? temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              fileSize > 0,
              fileSize <= maxArtworkBytes,
              let imageFormat = ImageFormat.resolve(response: response, sourceURL: sourceURL)
        else {
            return nil
        }

        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let localURL = directory.appending(path: "artwork.\(imageFormat.fileExtension)")

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temporaryURL, to: localURL)
            return try UNNotificationAttachment(
                identifier: "episode-artwork",
                url: localURL,
                options: [UNNotificationAttachmentOptionsTypeHintKey: imageFormat.typeIdentifier]
            )
        } catch {
            try? FileManager.default.removeItem(at: localURL)
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }
}
