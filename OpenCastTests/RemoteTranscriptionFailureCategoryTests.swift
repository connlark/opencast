import OpenCastTranscription
import Testing
@testable import OpenCast

@Suite("Remote transcription failure categories")
struct RemoteTranscriptionFailureCategoryTests {
    @Test("A parked phase is non-terminal and presents Resume with Cancel still available")
    func parkedPhasePresentsResume() throws {
        let phase = RemoteTranscriptionRequestPhase.parkedOnServer(.parked)
        #expect(!phase.isTerminal)
        #expect(phase.isParked)
        #expect(phase.displayText == RemoteTranscriptionStatusPresentation.parkedTitle)
        let presentation = try #require(RemoteTranscriptionStatusPresentation.make(phase: phase))
        #expect(presentation.isParked)
        #expect(presentation.offersResume)
        #expect(!presentation.offersRetry)
        #expect(!presentation.isTerminalFailure)
        #expect(!presentation.offersLocalFallback)
        #expect(presentation.title == RemoteTranscriptionStatusPresentation.parkedTitle)
    }

    @Test("Retryable terminal failures present Try Again; landed server failures present only the on-device fallback")
    func terminalFailuresPresentTheHonestAffordance() throws {
        let localFailure = try #require(RemoteTranscriptionStatusPresentation.make(phase: .failed(.localRequestFailed)))
        #expect(localFailure.isTerminalFailure)
        #expect(localFailure.offersRetry)
        #expect(!localFailure.offersResume)
        #expect(localFailure.offersLocalFallback)
        #expect(localFailure.detail == RemoteTranscriptionFailureCategory.localRequestFailed.message)

        let downloadFailure = try #require(RemoteTranscriptionStatusPresentation.make(phase: .failed(.downloadFailed)))
        #expect(downloadFailure.offersRetry)

        let unreachable = try #require(RemoteTranscriptionStatusPresentation.make(phase: .failed(.serviceUnavailable)))
        #expect(unreachable.offersRetry)

        let ackWithoutImport = try #require(
            RemoteTranscriptionStatusPresentation.make(phase: .failed(.acknowledgedWithoutLocalImport))
        )
        #expect(ackWithoutImport.title == "Transcript wasn't saved on this device")
        #expect(ackWithoutImport.offersRetry)
        #expect(ackWithoutImport.offersLocalFallback)

        let serverFailure = try #require(
            RemoteTranscriptionStatusPresentation.make(phase: .failed(.serverRejected(.transcriptionFailed)))
        )
        #expect(serverFailure.isTerminalFailure)
        #expect(!serverFailure.offersRetry)
        #expect(!serverFailure.offersResume)
        #expect(serverFailure.offersLocalFallback)
        #expect(serverFailure.title != ackWithoutImport.title)

        let mismatch = try #require(RemoteTranscriptionStatusPresentation.make(phase: .mismatchLocalFallback))
        #expect(mismatch.isTerminalFailure)
        #expect(!mismatch.offersRetry)
        #expect(mismatch.offersLocalFallback)

        let cancelled = try #require(RemoteTranscriptionStatusPresentation.make(phase: .cancelled))
        #expect(cancelled.isTerminalFailure)
        #expect(!cancelled.offersRetry)
        #expect(!cancelled.offersResume)
    }
}
