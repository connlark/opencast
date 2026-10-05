import Foundation
import UserNotifications
import Testing
@testable import OpenCast

@MainActor
@Suite("Remote transcription notification scheduler")
struct RemoteTranscriptionNotificationSchedulerTests {
    @Test("A backgrounded completion posts on the transcription category with its own thread and a no-op kind")
    func schedulesPinnedMetadata() async throws {
        let center = FakeAdFreePassNotificationCenter()
        let scheduler = RemoteTranscriptionNotificationScheduler(center: center)

        let decision = await scheduler.scheduleIfNeeded(
            phase: .completed,
            episodeTitle: "Episode One",
            deliveryOwner: .local,
            isSceneActive: false
        )

        #expect(decision == .scheduled)
        let request = try #require(center.addedRequests.first)
        #expect(center.addedRequests.count == 1)
        #expect(request.content.title == "Transcript ready")
        #expect(request.content.body == "Episode One")
        #expect(request.content.categoryIdentifier == OpenCastNotificationCategory.transcription)
        #expect(request.content.threadIdentifier == "opencast-remote-transcription")
        #expect(request.content.threadIdentifier == RemoteTranscriptionNotificationScheduler.threadIdentifier)
        #expect(request.identifier.hasPrefix(RemoteTranscriptionNotificationScheduler.threadIdentifier))
        #expect(request.content.sound != nil)
        #expect(request.trigger == nil)
        // The delegate routes only "episode" and "diagnostic"; this kind is
        // a deliberate no-op tap.
        let payload = request.content.userInfo["opencast"] as? [String: Any]
        #expect(payload?["kind"] as? String == "remote-transcription")
    }

    @Test("An active scene suppresses before any authorization read")
    func activeSceneSuppressesFirst() async {
        let center = FakeAdFreePassNotificationCenter()
        let scheduler = RemoteTranscriptionNotificationScheduler(center: center)

        for phase in [RemoteTranscriptionRequestPhase.completed, .parkedOnServer(.parked)] {
            let decision = await scheduler.scheduleIfNeeded(
                phase: phase,
                episodeTitle: "Episode",
                deliveryOwner: .local,
                isSceneActive: true
            )
            #expect(decision == .suppressed(.sceneActive), "phase \(phase)")
        }

        #expect(center.addedRequests.isEmpty)
        #expect(center.authorizationStatusReadCount == 0)
    }

    @Test("Authorization gates delivery: denied and undetermined suppress, provisional delivers")
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
            let scheduler = RemoteTranscriptionNotificationScheduler(center: center)

            let decision = await scheduler.scheduleIfNeeded(
                phase: .completed,
                episodeTitle: "Episode",
                deliveryOwner: .local,
                isSceneActive: false
            )

            let expected: CompletionDeliveryDecision = expectsDelivery ? .scheduled : .suppressed(.unauthorized)
            #expect(decision == expected, "status \(status)")
            #expect(center.addedRequests.count == (expectsDelivery ? 1 : 0), "status \(status)")
            #expect(center.authorizationStatusReadCount == 1, "status \(status)")
        }
    }

    @Test("A remote owner suppresses the completion and a failure before reading authorization, but never the paused notification")
    func remoteOwnerSuppressesCompletionOnly() async throws {
        let center = FakeAdFreePassNotificationCenter()
        let scheduler = RemoteTranscriptionNotificationScheduler(center: center)

        for phase in [RemoteTranscriptionRequestPhase.completed, .failed(.serverRejected(.internalError))] {
            let decision = await scheduler.scheduleIfNeeded(
                phase: phase,
                episodeTitle: "Episode",
                deliveryOwner: .remote,
                isSceneActive: false
            )
            #expect(decision == .suppressed(.remoteOwner), "phase \(phase)")
        }
        #expect(center.addedRequests.isEmpty)
        #expect(center.authorizationStatusReadCount == 0)

        let paused = await scheduler.scheduleIfNeeded(
            phase: .parkedOnServer(.parked),
            episodeTitle: "Episode",
            deliveryOwner: .remote,
            isSceneActive: false,
            createState: .attached
        )
        #expect(paused == .scheduled)
        let request = try #require(center.addedRequests.first)
        #expect(center.addedRequests.count == 1)
        #expect(request.content.title == "Still running on the server")
        #expect(request.content.body == RemoteTranscriptionStatusPresentation.parkedDetail(for: .parked))
        #expect(request.content.categoryIdentifier == OpenCastNotificationCategory.transcription)
        #expect(request.content.threadIdentifier == RemoteTranscriptionNotificationScheduler.threadIdentifier)
    }

    @Test("Silent endings never read authorization or reach add")
    func silentEndingsNeverReachAdd() async {
        let center = FakeAdFreePassNotificationCenter()
        let scheduler = RemoteTranscriptionNotificationScheduler(center: center)

        for phase in [
            RemoteTranscriptionRequestPhase.parkedOnServer(.connectionLost),
            .parkedOnServer(.localRequestFailed),
            .cancelled,
            .verifying,
        ] {
            let decision = await scheduler.scheduleIfNeeded(
                phase: phase,
                episodeTitle: "Episode",
                deliveryOwner: .local,
                isSceneActive: false
            )
            #expect(decision == .suppressed(.silentOutcome), "phase \(phase)")
        }

        #expect(center.addedRequests.isEmpty)
        #expect(center.authorizationStatusReadCount == 0)
    }

    @Test("A refused add reports the failure")
    func refusedAddReportsFailure() async {
        let center = FakeAdFreePassNotificationCenter()
        center.addError = CocoaError(.featureUnsupported)
        let scheduler = RemoteTranscriptionNotificationScheduler(center: center)

        let decision = await scheduler.scheduleIfNeeded(
            phase: .completed,
            episodeTitle: "Episode",
            deliveryOwner: .local,
            isSceneActive: false
        )

        #expect(decision == .addFailed)
        #expect(center.addedRequests.isEmpty)
    }
}
