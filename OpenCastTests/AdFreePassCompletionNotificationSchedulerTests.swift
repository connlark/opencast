import Foundation
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

        let decision = await scheduler.scheduleIfNeeded(
            terminal: .drained(completedCount: 1, failedCount: 1),
            outcomes: [
                completedOutcome(episodeID: "a", zoneCount: 3),
                failedOutcome(episodeID: "b"),
            ],
            isSceneActive: false
        )

        #expect(decision == .scheduled)
        let request = try #require(center.addedRequests.first)
        #expect(center.addedRequests.count == 1)
        #expect(request.content.title == "Found 3 ad breaks in 1 episode")
        #expect(request.content.body == "1 episode couldn't be analyzed.")
        #expect(request.content.categoryIdentifier == OpenCastNotificationCategory.adFreePass)
        #expect(request.content.sound != nil)
        #expect(request.trigger == nil)
        #expect(request.identifier.hasPrefix(AdFreePassCompletionNotificationScheduler.threadIdentifier))
        #expect(request.content.threadIdentifier == AdFreePassCompletionNotificationScheduler.threadIdentifier)

        let payload = request.content.userInfo["opencast"] as? [String: Any]
        #expect(payload?["kind"] as? String == "ad-free-pass")
    }

    @Test("A pause holding an unattended item posts nothing; a manual item's pause posts as before")
    func heldUnattendedPauseStaysSilent() async throws {
        let center = FakeAdFreePassNotificationCenter()
        let scheduler = AdFreePassCompletionNotificationScheduler(center: center)

        let held = await scheduler.scheduleIfNeeded(
            terminal: .interrupted,
            outcomes: [],
            isSceneActive: false,
            isHoldingUnattendedItem: true
        )
        #expect(held == .suppressed(.silentOutcome))
        #expect(center.addedRequests.isEmpty)

        let manual = await scheduler.scheduleIfNeeded(
            terminal: .interrupted,
            outcomes: [],
            isSceneActive: false
        )
        #expect(manual == .scheduled)
        #expect(try #require(center.addedRequests.first).content.title == "Ad detection paused")
    }

    @Test("An active scene suppresses scheduling before any settings read")
    func activeSceneSuppresses() async {
        let center = FakeAdFreePassNotificationCenter()
        let scheduler = AdFreePassCompletionNotificationScheduler(center: center)

        let decision = await scheduler.scheduleIfNeeded(
            terminal: .drained(completedCount: 1, failedCount: 0),
            outcomes: [completedOutcome(episodeID: "a", zoneCount: 2)],
            isSceneActive: true
        )

        #expect(decision == .suppressed(.sceneActive))
        #expect(center.addedRequests.isEmpty)
        #expect(center.authorizationStatusReadCount == 0)
    }

    @Test("An expiration park of a cloud item posts the server-still-working copy on the pinned category and thread, for either owner")
    func cloudParkSchedulesServerStillWorkingCopy() async throws {
        let center = FakeAdFreePassNotificationCenter()
        let scheduler = AdFreePassCompletionNotificationScheduler(center: center)

        let decision = await scheduler.scheduleIfNeeded(
            terminal: .remoteParked(.parked),
            outcomes: [completedOutcome(episodeID: "a", zoneCount: 2, owner: .remote)],
            isSceneActive: false
        )

        #expect(decision == .scheduled)
        let request = try #require(center.addedRequests.first)
        #expect(center.addedRequests.count == 1)
        #expect(request.content.title == "Still running on the server")
        #expect(request.content.body == RemoteTranscriptionStatusPresentation.parkedDetail(for: .parked))
        #expect(request.content.categoryIdentifier == OpenCastNotificationCategory.adFreePass)
        #expect(request.content.threadIdentifier == AdFreePassCompletionNotificationScheduler.threadIdentifier)
        let payload = request.content.userInfo["opencast"] as? [String: Any]
        #expect(payload?["kind"] as? String == "ad-free-pass")
    }

    // MARK: - Fixtures

    private func completedOutcome(
        episodeID: String,
        zoneCount: Int,
        owner: JobCompletionDeliveryOwner = .local
    ) -> AdFreePassQueueItemOutcome {
        AdFreePassQueueItemOutcome(
            episodeID: episodeID,
            episodeTitle: "Episode \(episodeID)",
            artworkURL: nil,
            kind: .completed(zoneCount: zoneCount),
            completionDeliveryOwner: owner
        )
    }

    private func failedOutcome(episodeID: String) -> AdFreePassQueueItemOutcome {
        AdFreePassQueueItemOutcome(
            episodeID: episodeID,
            episodeTitle: "Episode \(episodeID)",
            artworkURL: nil,
            kind: .failed(message: "Download failed."),
            completionDeliveryOwner: .local
        )
    }
}
