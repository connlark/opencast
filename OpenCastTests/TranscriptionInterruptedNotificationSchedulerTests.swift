import UserNotifications
import Testing
@testable import OpenCast

@MainActor
@Suite("Transcription interruption notification scheduler")
struct TranscriptionInterruptedNotificationSchedulerTests {
    @Test("Backgrounded authorized interruption posts pinned notification metadata")
    func schedulesWhenBackgroundedAndAuthorized() async throws {
        let center = FakeAdFreePassNotificationCenter()
        let scheduler = TranscriptionInterruptedNotificationScheduler(center: center)
        let content = TranscriptionInterruptedNotificationContent(
            episodeTitle: "Episode",
            restoredPriorTranscript: false
        )

        await scheduler.scheduleIfNeeded(content: content, isSceneActive: false)

        let request = try #require(center.addedRequests.first)
        #expect(center.addedRequests.count == 1)
        #expect(request.content.title == content.title)
        #expect(request.content.body == content.body)
        #expect(request.content.categoryIdentifier == OpenCastNotificationCategory.transcription)
        #expect(request.content.threadIdentifier == TranscriptionInterruptedNotificationScheduler.threadIdentifier)
        #expect(request.identifier.hasPrefix(TranscriptionInterruptedNotificationScheduler.threadIdentifier))
        #expect(request.content.sound != nil)
        #expect(request.trigger == nil)
        let payload = request.content.userInfo["opencast"] as? [String: Any]
        #expect(payload?["kind"] as? String == "transcription-interrupted")
    }

    @Test("Active scene suppresses scheduling before reading authorization")
    func activeSceneSuppresses() async {
        let center = FakeAdFreePassNotificationCenter()
        let scheduler = TranscriptionInterruptedNotificationScheduler(center: center)

        await scheduler.scheduleIfNeeded(
            content: TranscriptionInterruptedNotificationContent(
                episodeTitle: nil,
                restoredPriorTranscript: true
            ),
            isSceneActive: true
        )

        #expect(center.addedRequests.isEmpty)
        #expect(center.authorizationStatusReadCount == 0)
    }

    @Test("Denied authorization suppresses delivery")
    func deniedAuthorizationSuppresses() async {
        let center = FakeAdFreePassNotificationCenter()
        center.authorizationStatusValue = .denied
        let scheduler = TranscriptionInterruptedNotificationScheduler(center: center)

        await scheduler.scheduleIfNeeded(
            content: TranscriptionInterruptedNotificationContent(
                episodeTitle: nil,
                restoredPriorTranscript: false
            ),
            isSceneActive: false
        )

        #expect(center.authorizationStatusReadCount == 1)
        #expect(center.addedRequests.isEmpty)
    }
}
