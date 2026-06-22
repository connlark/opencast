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
            content.title = "The Rest Is Science"
            content.subtitle = "A Paleontology Of The Future"
            content.body = "What will humanity leave behind? In this episode, Professor Hannah Fry and VSauce's Michael Stevens explore the traces humans leave behind."
            content.categoryIdentifier = OpenCastNotificationCategory.episode
            content.threadIdentifier = "opencast-notification-look-fixture"
            content.targetContentIdentifier = "opencast-notification-look-fixture-episode"
            content.userInfo = [
                "opencast": [
                    "kind": "episode",
                    "podcast_title": "The Rest Is Science",
                    "episode_title": "A Paleontology Of The Future",
                    "episode_duration_text": "1 HR 6 MIN",
                    "episode_summary": "What will humanity leave behind? In this episode, Professor Hannah Fry and VSauce's Michael Stevens explore the traces humans leave behind.",
                    "feed_url": "https://example.com/notification-look-fixture.xml",
                    "episode_id": "opencast-notification-look-fixture-episode",
                ],
            ]
            if let attachment = try? artworkAttachment() {
                content.attachments = [attachment]
            }

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

    private static func artworkAttachment() throws -> UNNotificationAttachment {
        let directory = URL.temporaryDirectory.appending(
            path: "opencast-notification-look-fixture",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appending(path: "artwork.png")
        try artworkPNGData().write(to: url, options: .atomic)
        return try UNNotificationAttachment(identifier: "artwork", url: url)
    }

    private static func artworkPNGData() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format)
        guard let data = renderer.image(actions: drawArtwork).pngData() else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    private static func drawArtwork(context: UIGraphicsImageRendererContext) {
        context.cgContext.setFillColor(UIColor(red: 0.05, green: 0.12, blue: 0.11, alpha: 1).cgColor)
        context.cgContext.fill(CGRect(x: 0, y: 0, width: 256, height: 256))

        context.cgContext.setFillColor(UIColor(red: 0.63, green: 0.88, blue: 0.82, alpha: 1).cgColor)
        context.cgContext.fillEllipse(in: CGRect(x: 34, y: 34, width: 188, height: 188))

        context.cgContext.setFillColor(UIColor(red: 0.03, green: 0.08, blue: 0.08, alpha: 1).cgColor)
        context.cgContext.fillEllipse(in: CGRect(x: 58, y: 58, width: 140, height: 140))

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 36, weight: .bold),
            .foregroundColor: UIColor(red: 0.82, green: 0.96, blue: 0.91, alpha: 1),
            .paragraphStyle: paragraph,
        ]
        NSString(string: "SCIENCE").draw(
            in: CGRect(x: 16, y: 106, width: 224, height: 52),
            withAttributes: attributes
        )
    }
}
