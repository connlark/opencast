import UserNotifications
import Testing
@testable import OpenCast

@MainActor
@Suite("Ad-free pass completion notification scheduler")
struct AdFreePassCompletionNotificationSchedulerTests {
    @Test("Backgrounded drained queue posts the ad-free-pass notification")
    func schedulesWhenBackgroundedAndAuthorized() async throws {
        let center = FakeAdFreePassNotificationCenter()
        let scheduler = AdFreePassCompletionNotificationScheduler(center: center)

        await scheduler.scheduleIfNeeded(
            terminal: .drained(completedCount: 1, failedCount: 1),
            outcomes: [
                completedOutcome(episodeID: "a", zoneCount: 3),
                failedOutcome(episodeID: "b"),
            ],
            isSceneActive: false
        )

        let request = try #require(center.addedRequests.first)
        #expect(center.addedRequests.count == 1)
        #expect(request.content.title == "Found 3 ad breaks in 1 episode")
        #expect(request.content.body == "1 episode couldn't be analyzed.")
        #expect(request.content.categoryIdentifier == OpenCastNotificationCategory.adFreePass)
        #expect(request.content.sound != nil)
        // Immediate delivery, unique per drain, grouped under one thread.
        #expect(request.trigger == nil)
        #expect(request.identifier.hasPrefix(AdFreePassCompletionNotificationScheduler.threadIdentifier))
        #expect(request.content.threadIdentifier == AdFreePassCompletionNotificationScheduler.threadIdentifier)

        // The kind is a routing no-op — never "episode" or "diagnostic".
        let payload = request.content.userInfo["opencast"] as? [String: Any]
        #expect(payload?["kind"] as? String == "ad-free-pass")
    }

    @Test("An active scene suppresses scheduling before any settings read")
    func activeSceneSuppresses() async {
        let center = FakeAdFreePassNotificationCenter()
        let scheduler = AdFreePassCompletionNotificationScheduler(center: center)

        await scheduler.scheduleIfNeeded(
            terminal: .drained(completedCount: 1, failedCount: 0),
            outcomes: [completedOutcome(episodeID: "a", zoneCount: 2)],
            isSceneActive: true
        )

        #expect(center.addedRequests.isEmpty)
        #expect(center.authorizationStatusReadCount == 0)
    }

    @Test("Authorization gates delivery")
    func authorizationTable() async {
        for (status, expectsDelivery) in [
            (UNAuthorizationStatus.authorized, true),
            (.provisional, true),
            (.ephemeral, true),
            (.denied, false),
            (.notDetermined, false),
        ] {
            let center = FakeAdFreePassNotificationCenter()
            center.authorizationStatusValue = status
            let scheduler = AdFreePassCompletionNotificationScheduler(center: center)

            await scheduler.scheduleIfNeeded(
                terminal: .drained(completedCount: 1, failedCount: 0),
                outcomes: [completedOutcome(episodeID: "a", zoneCount: 2)],
                isSceneActive: false
            )

            #expect(center.addedRequests.count == (expectsDelivery ? 1 : 0), "status \(status)")
        }
    }

    @Test("Deferred terminals never notify even when backgrounded and authorized")
    func deferredTerminalsNeverNotify() async {
        let center = FakeAdFreePassNotificationCenter()
        let scheduler = AdFreePassCompletionNotificationScheduler(center: center)

        for terminal in [AdFreePassQueueTerminalOutcome.capDeferred, .awaitingConsent] {
            await scheduler.scheduleIfNeeded(
                terminal: terminal,
                outcomes: [completedOutcome(episodeID: "a", zoneCount: 2)],
                isSceneActive: false
            )
        }

        #expect(center.addedRequests.isEmpty)
    }

    @Test("Interrupted terminals schedule the paused notification")
    func interruptedTerminalSchedulesPausedNotification() async throws {
        let center = FakeAdFreePassNotificationCenter()
        let scheduler = AdFreePassCompletionNotificationScheduler(center: center)

        await scheduler.scheduleIfNeeded(
            terminal: .interrupted,
            outcomes: [completedOutcome(episodeID: "a", zoneCount: 2)],
            isSceneActive: false
        )

        let request = try #require(center.addedRequests.first)
        #expect(center.addedRequests.count == 1)
        #expect(request.content.title == "Ad detection paused")
        #expect(request.content.body.contains("pick up where it left off"))
    }

    // MARK: - Fixtures

    private func completedOutcome(episodeID: String, zoneCount: Int) -> AdFreePassQueueItemOutcome {
        AdFreePassQueueItemOutcome(
            episodeID: episodeID,
            episodeTitle: "Episode \(episodeID)",
            artworkURL: nil,
            kind: .completed(zoneCount: zoneCount)
        )
    }

    private func failedOutcome(episodeID: String) -> AdFreePassQueueItemOutcome {
        AdFreePassQueueItemOutcome(
            episodeID: episodeID,
            episodeTitle: "Episode \(episodeID)",
            artworkURL: nil,
            kind: .failed(message: "Download failed.")
        )
    }
}
