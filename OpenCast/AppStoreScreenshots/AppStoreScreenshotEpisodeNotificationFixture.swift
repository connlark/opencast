#if DEBUG
import UserNotifications

/// Screenshot-lane-only: delivers a marketing-clean new-episode notification
/// for the primary seed episode eight seconds after launch (time for the UI
/// test to reach the Library) so the App Store
/// set can capture the rich card on SpringBoard. Seed-catalog copy and the
/// bundled cover art stand in for the real feed payload.
enum AppStoreScreenshotEpisodeNotificationFixture {
    static func schedule() {
        Task {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            center.removePendingNotificationRequests(withIdentifiers: [requestIdentifier])
            center.removeDeliveredNotifications(withIdentifiers: [requestIdentifier])

            let podcastTitle = AppStoreScreenshotSeedCatalog.primaryPodcastTitle
            let episodeTitle = AppStoreScreenshotSeedCatalog.primaryEpisodeTitle
            let summary = AppStoreScreenshotSeedCatalog.primaryEpisodeSummary
            let episodeID = AppStoreScreenshotSeedCatalog.primaryEpisodeID

            let content = UNMutableNotificationContent()
            content.title = podcastTitle
            content.subtitle = episodeTitle
            content.body = summary
            content.categoryIdentifier = OpenCastNotificationCategory.episode
            content.threadIdentifier = "opencast-app-store-episode-notification"
            content.targetContentIdentifier = episodeID
            content.userInfo = [
                "opencast": [
                    "kind": "episode",
                    "podcast_title": podcastTitle,
                    "episode_title": episodeTitle,
                    "episode_duration_text": "49 MIN",
                    "episode_summary": summary,
                    "feed_url": AppStoreScreenshotSeedCatalog.primaryFeedURL,
                    "episode_id": episodeID,
                ],
            ]
            content.attachments = (try? artworkAttachments()) ?? []

            let request = UNNotificationRequest(
                identifier: requestIdentifier,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 8, repeats: false)
            )
            try? await center.add(request)
        }
    }

    private static let requestIdentifier = "opencast-app-store-episode-notification-fixture"

    // UNNotificationAttachment takes ownership of its file, so each
    // attachment gets its own copy of the bundled cover.
    private static func artworkAttachments() throws -> [UNNotificationAttachment] {
        guard let artworkURL = Bundle.main.url(
            forResource: AppStoreScreenshotSeedCatalog.primaryArtworkName,
            withExtension: "png",
            subdirectory: "AppStoreScreenshots/Artwork"
        ) else {
            throw AppStoreScreenshotSeedArtworkError.missing(
                name: AppStoreScreenshotSeedCatalog.primaryArtworkName,
                subdirectory: "AppStoreScreenshots/Artwork"
            )
        }

        let directory = URL.temporaryDirectory.appending(
            path: "opencast-app-store-episode-notification",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        return try [
            (NotificationArtworkAttachmentIdentifier.podcast, "show-art.png"),
            (NotificationArtworkAttachmentIdentifier.episode, "episode-art.png"),
        ].map { identifier, fileName in
            let url = directory.appending(path: fileName)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: artworkURL, to: url)
            return try UNNotificationAttachment(identifier: identifier, url: url)
        }
    }
}
#endif
