#if DEBUG
import UserNotifications

/// Screenshot-lane-only: delivers a marketing-clean ad-free-pass completion
/// notification a few seconds after launch so the App Store set can capture
/// the real copy and category on SpringBoard. Unlike the UI-test look
/// fixture, this variant reports no failures.
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
                        episodeID: "app-store-signal-path-episode-1",
                        episodeTitle: "Tracing the Bug That Only Appeared at Night",
                        artworkURL: nil,
                        kind: .completed(zoneCount: 3)
                    ),
                    AdFreePassQueueItemOutcome(
                        episodeID: "app-store-signal-path-episode-2",
                        episodeTitle: "Designing Alerts People Actually Read",
                        artworkURL: nil,
                        kind: .completed(zoneCount: 4)
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
