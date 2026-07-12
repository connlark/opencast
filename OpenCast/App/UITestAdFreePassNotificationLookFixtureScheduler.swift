import UserNotifications

/// UI-test-only: delivers the ad-free-pass completion notification a few
/// seconds after launch so a springboard screenshot can capture the real
/// copy, category, and payload built by the production scheduler.
enum UITestAdFreePassNotificationLookFixtureScheduler {
    static func schedule() {
        Task {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            center.removePendingNotificationRequests(withIdentifiers: [requestIdentifier])
            center.removeDeliveredNotifications(withIdentifiers: [requestIdentifier])

            guard let content = AdFreePassCompletionNotificationContent(
                terminal: .drained(completedCount: 2, failedCount: 1),
                outcomes: [
                    AdFreePassQueueItemOutcome(
                        episodeID: "adfreepass-look-fixture-episode-1",
                        episodeTitle: "866: Very Nice",
                        artworkURL: nil,
                        kind: .completed(zoneCount: 4)
                    ),
                    AdFreePassQueueItemOutcome(
                        episodeID: "adfreepass-look-fixture-episode-2",
                        episodeTitle: "867: A Small Fortune",
                        artworkURL: nil,
                        kind: .completed(zoneCount: 3)
                    ),
                    AdFreePassQueueItemOutcome(
                        episodeID: "adfreepass-look-fixture-episode-3",
                        episodeTitle: "868: Off Course",
                        artworkURL: nil,
                        kind: .failed(message: "Download failed.")
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

    private static let requestIdentifier = "opencast-adfreepass-notification-look-fixture"
}
