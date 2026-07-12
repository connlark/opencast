import UIKit
import UserNotifications

enum UITestNotificationLookFixtureScheduler {
    static func schedule() {
        Task {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            center.removePendingNotificationRequests(withIdentifiers: [requestIdentifier])
            center.removeDeliveredNotifications(withIdentifiers: [requestIdentifier])

            let content = UNMutableNotificationContent()
            content.title = "This American Life"
            content.subtitle = "866: Very Nice"
            content.body = "Stories from people trying very hard to be nice."
            content.categoryIdentifier = OpenCastNotificationCategory.episode
            content.threadIdentifier = "opencast-notification-look-fixture"
            content.targetContentIdentifier = "opencast-notification-look-fixture-episode"
            content.userInfo = [
                "opencast": [
                    "kind": "episode",
                    "podcast_title": "This American Life",
                    "episode_title": "866: Very Nice",
                    "episode_duration_text": "59 MIN",
                    "episode_summary": "Stories from people trying very hard to be nice.",
                    "artwork_url": "https://assets.thisamericanlife.org/show-art.jpg",
                    "episode_artwork_url": "https://assets.thisamericanlife.org/episodes/866-art.jpg",
                    "feed_url": "https://feeds.thisamericanlife.org/talpodcast",
                    "episode_id": "opencast-notification-look-fixture-episode",
                ],
            ]
            content.attachments = (try? artworkAttachments()) ?? []

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 4, repeats: false)
            let request = UNNotificationRequest(
                identifier: requestIdentifier,
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }

    private static let requestIdentifier = "opencast-notification-look-fixture"

    private static func artworkAttachments() throws -> [UNNotificationAttachment] {
        [
            try artworkAttachment(
                identifier: NotificationArtworkAttachmentIdentifier.podcast,
                fileName: "show-art.png",
                draw: drawShowArtwork
            ),
            try artworkAttachment(
                identifier: NotificationArtworkAttachmentIdentifier.episode,
                fileName: "episode-art.png",
                draw: drawEpisodeArtwork
            ),
        ]
    }

    private static func artworkAttachment(
        identifier: String,
        fileName: String,
        draw: (UIGraphicsImageRendererContext) -> Void
    ) throws -> UNNotificationAttachment {
        let directory = URL.temporaryDirectory.appending(
            path: "opencast-notification-look-fixture",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appending(path: fileName)
        try artworkPNGData(draw: draw).write(to: url, options: .atomic)
        return try UNNotificationAttachment(identifier: identifier, url: url)
    }

    private static func artworkPNGData(
        draw: (UIGraphicsImageRendererContext) -> Void
    ) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format)
        guard let data = renderer.image(actions: draw).pngData() else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    private static func drawShowArtwork(context: UIGraphicsImageRendererContext) {
        context.cgContext.setFillColor(UIColor(red: 0.03, green: 0.08, blue: 0.13, alpha: 1).cgColor)
        context.cgContext.fill(CGRect(x: 0, y: 0, width: 256, height: 256))

        context.cgContext.setFillColor(UIColor(red: 0.98, green: 0.82, blue: 0.18, alpha: 1).cgColor)
        context.cgContext.fill(CGRect(x: 28, y: 28, width: 200, height: 200))

        context.cgContext.setFillColor(UIColor(red: 0.03, green: 0.08, blue: 0.13, alpha: 1).cgColor)
        context.cgContext.fill(CGRect(x: 48, y: 48, width: 160, height: 160))

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 54, weight: .bold),
            .foregroundColor: UIColor(red: 0.98, green: 0.82, blue: 0.18, alpha: 1),
            .paragraphStyle: paragraph,
        ]
        NSString(string: "TAL").draw(
            in: CGRect(x: 16, y: 94, width: 224, height: 72),
            withAttributes: attributes
        )
    }

    private static func drawEpisodeArtwork(context: UIGraphicsImageRendererContext) {
        context.cgContext.setFillColor(UIColor(red: 0.69, green: 0.12, blue: 0.11, alpha: 1).cgColor)
        context.cgContext.fill(CGRect(x: 0, y: 0, width: 256, height: 256))

        context.cgContext.setFillColor(UIColor(red: 0.98, green: 0.92, blue: 0.82, alpha: 1).cgColor)
        context.cgContext.fillEllipse(in: CGRect(x: 28, y: 28, width: 200, height: 200))

        context.cgContext.setFillColor(UIColor(red: 0.69, green: 0.12, blue: 0.11, alpha: 1).cgColor)
        context.cgContext.fillEllipse(in: CGRect(x: 58, y: 58, width: 140, height: 140))

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 50, weight: .bold),
            .foregroundColor: UIColor(red: 0.98, green: 0.92, blue: 0.82, alpha: 1),
            .paragraphStyle: paragraph,
        ]
        NSString(string: "866").draw(
            in: CGRect(x: 16, y: 96, width: 224, height: 68),
            withAttributes: attributes
        )
    }
}
