#if DEBUG
import UserNotifications

enum AppStoreScreenshotNotificationFixture {
    static func schedule() {
        Task {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            center.removePendingNotificationRequests(withIdentifiers: [requestIdentifier])
            center.removeDeliveredNotifications(withIdentifiers: [requestIdentifier])

            guard let content = AdFreePassCompletionNotificationContent(
                terminal: .drained(completedCount: 2, failedCount: 0),
                outcomes: [
                    AdFreePassQueueItemOutcome(
                        episodeID: AppStoreScreenshotSeedCatalog.primaryEpisodeID,
                        episodeTitle: AppStoreScreenshotSeedCatalog.primaryEpisodeTitle,
                        artworkURL: nil,
                        kind: .completed(zoneCount: 3),
                        completionDeliveryOwner: .local
                    ),
                    AdFreePassQueueItemOutcome(
                        episodeID: "app-store-orbit-report-episode-2",
                        episodeTitle: "Why Every Comet Is a Surprise",
                        artworkURL: nil,
                        kind: .completed(zoneCount: 4),
                        completionDeliveryOwner: .local
                    ),
                ]
            ) else {
                return
            }

            let request = UNNotificationRequest(
                identifier: requestIdentifier,
                content: AdFreePassCompletionNotificationScheduler.notificationContent(for: content),
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 4, repeats: false)
            )
            try? await center.add(request)
        }
    }

    private static let requestIdentifier = "opencast-app-store-notification-fixture"
}
#endif
