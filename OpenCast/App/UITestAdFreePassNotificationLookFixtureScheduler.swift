import UserNotifications

/// UI-test-only: delivers the ad-free-pass completion notification a few
/// seconds after launch so a springboard screenshot can capture the real
/// copy, category, and payload built by the production scheduler.
enum UITestAdFreePassNotificationLookFixtureScheduler {
    static func schedule() {
        Task {
            AdFreePassBackgroundRunLog.record("notification look fixture requesting authorization")
            let center = UNUserNotificationCenter.current()
            do {
                let authorized = try await center.requestAuthorization(options: [.alert, .sound])
                AdFreePassBackgroundRunLog.record("notification look fixture authorized=\(authorized)")
            } catch {
                AdFreePassBackgroundRunLog.record("notification look fixture authorization failed: \(error)")
            }
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
            do {
                try await center.add(request)
                let settings = await center.notificationSettings()
                let pending = await center.pendingNotificationRequests()
                AdFreePassBackgroundRunLog.record("notification look fixture scheduled status=\(settings.authorizationStatus.rawValue) pending=\(pending.count)")
            } catch {
                AdFreePassBackgroundRunLog.record("notification look fixture add failed: \(error)")
            }
        }
    }

    private static let requestIdentifier = "opencast-adfreepass-notification-look-fixture"
}
