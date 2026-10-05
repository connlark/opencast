import Testing
@testable import OpenCast

@MainActor
@Suite("Remote transcription notification content")
struct RemoteTranscriptionNotificationContentTests {
    @Test("A completed run says the transcript is ready and names the episode")
    func completedCopy() throws {
        let titled = try #require(RemoteTranscriptionNotificationContent(
            phase: .completed,
            episodeTitle: "Episode One"
        ))
        #expect(titled.kind == .completed)
        #expect(titled.title == "Transcript ready")
        #expect(titled.body == "Episode One")
        #expect(titled.honorsDeliveryOwner)

        let untitled = try #require(RemoteTranscriptionNotificationContent(phase: .completed, episodeTitle: nil))
        #expect(untitled.title == "Transcript ready")
        #expect(untitled.body.isEmpty)
    }

    @Test(
        "An expiration park after a create attempt says the server is still working",
        arguments: [RemoteTranscriptionJobCreateState.createAttempted, .attached]
    )
    func expirationParkCopy(createState: RemoteTranscriptionJobCreateState) throws {
        let content = try #require(RemoteTranscriptionNotificationContent(
            phase: .parkedOnServer(.parked),
            episodeTitle: "Episode One",
            createState: createState
        ))

        #expect(content.kind == .paused)
        #expect(content.title == RemoteTranscriptionStatusPresentation.parkedTitle)
        #expect(content.title == "Still running on the server")
        #expect(content.body == RemoteTranscriptionStatusPresentation.parkedDetail(for: .parked))
        #expect(!content.honorsDeliveryOwner)
    }

    @Test(
        "An expiration before a create attempt asks the person to resume without claiming server work",
        arguments: [RemoteTranscriptionJobCreateState?.none, .prepared]
    )
    func expirationBeforeCreateCopy(createState: RemoteTranscriptionJobCreateState?) throws {
        let content = try #require(RemoteTranscriptionNotificationContent(
            phase: .parkedOnServer(.parked),
            episodeTitle: "Episode One",
            createState: createState
        ))

        #expect(content.kind == .paused)
        #expect(content.title == "Remote transcription paused")
        #expect(content.body == "The server job hasn't started. Open OpenCast and resume to try again.")
        #expect(!content.honorsDeliveryOwner)
    }

    @Test("Only an expiration park has paused copy; the other exits stay silent")
    func onlyExpirationParksNotify() throws {
        let copy = try #require(RemoteTranscriptionNotificationContent.pausedCopy(for: .parked))
        #expect(copy.title == RemoteTranscriptionStatusPresentation.parkedTitle)
        #expect(copy.body == RemoteTranscriptionStatusPresentation.parkedDetail(for: .parked))

        for exit in [RemoteTranscriptionJobExit.connectionLost, .localRequestFailed, .downloadFailed] {
            #expect(RemoteTranscriptionNotificationContent.pausedCopy(for: exit) == nil, "exit \(exit)")
            #expect(
                RemoteTranscriptionNotificationContent(phase: .parkedOnServer(exit), episodeTitle: "Episode") == nil,
                "exit \(exit)"
            )
        }
    }

    @Test("A failed run carries the status card's title and reason, and belongs to the delivery owner")
    func failureCopy() throws {
        let rejected = try #require(RemoteTranscriptionNotificationContent(
            phase: .failed(.serverRejected(.internalError)),
            episodeTitle: "Episode One"
        ))
        #expect(rejected.kind == .failed)
        #expect(rejected.title == "Remote transcription didn't finish")
        #expect(rejected.body == RemoteTranscriptionFailureCategory.serverRejected(.internalError).message)
        #expect(rejected.honorsDeliveryOwner)

        let mismatch = try #require(RemoteTranscriptionNotificationContent(
            phase: .mismatchLocalFallback,
            episodeTitle: nil
        ))
        #expect(mismatch.kind == .failed)
        #expect(mismatch.title == "Server audio differed")
        #expect(mismatch.body == "The server fetched different audio than this device has. Transcribe on this device instead.")

        let unsaved = try #require(RemoteTranscriptionNotificationContent(
            phase: .failed(.acknowledgedWithoutLocalImport),
            episodeTitle: nil
        ))
        #expect(unsaved.title == "Transcript wasn't saved on this device")
        #expect(unsaved.body == RemoteTranscriptionFailureCategory.acknowledgedWithoutLocalImport.message)
    }

    @Test("Live phases and a cancel never notify")
    func livePhasesAndCancelStaySilent() {
        let phases: [RemoteTranscriptionRequestPhase] = [
            .preparing,
            .downloadingBoth,
            .verifying,
            .waitingForCredits,
            .uploadingExactCopy(completedParts: 1, totalParts: 4),
            .saving,
            .cancelled,
        ]
        for phase in phases {
            #expect(
                RemoteTranscriptionNotificationContent(phase: phase, episodeTitle: "Episode") == nil,
                "phase \(phase)"
            )
        }
    }
}
