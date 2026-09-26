import OpenCastTranscription
import Testing
@testable import OpenCast

/// Each exit disposition renders distinct copy and the honest affordance:
/// a parked job offers Resume, a local or download give-up offers Try
/// Again, and a landed server failure offers only the on-device fallback.
@Suite("Remote transcription failure categories")
struct RemoteTranscriptionFailureCategoryTests {
    @Test("Local request failure, connection loss, download failure and landed server errors have distinct copy")
    func exitDispositionsHaveDistinctCopy() {
        let categories: [RemoteTranscriptionFailureCategory] = [
            .localRequestFailed,
            .connectionLost,
            .downloadFailed,
            .serviceUnavailable,
            .serverRejected(.internalError),
            .serverRejected(.sourceMismatch),
            .acknowledgedWithoutLocalImport,
            .resultInvalid,
        ]
        let messages = categories.map(\.message)
        #expect(Set(messages).count == messages.count)
        #expect(messages.allSatisfy { !$0.isEmpty })
    }

    @Test("Run errors map onto their own categories")
    func runErrorsMapToCategories() {
        #expect(RemoteTranscriptionJobRunError.connectionLost.failureCategory == .connectionLost)
        #expect(RemoteTranscriptionJobRunError.localRequestFailed.failureCategory == .localRequestFailed)
        #expect(RemoteTranscriptionJobRunError.acknowledgedWithoutLocalImport.failureCategory == .acknowledgedWithoutLocalImport)
        #expect(RemoteTranscriptionJobRunError.downloadFailed.failureCategory == .downloadFailed)
        #expect(RemoteTranscriptionJobRunError.serviceUnavailable.failureCategory == .serviceUnavailable)
        #expect(RemoteTranscriptionJobRunError.serverRejected(.rateLimited).failureCategory == .serverRejected(.rateLimited))
    }

    @Test("A parked phase is non-terminal and presents Resume with Cancel still available")
    func parkedPhasePresentsResume() throws {
        for exit in [RemoteTranscriptionJobExit.parked, .connectionLost, .localRequestFailed, .downloadFailed] {
            let phase = RemoteTranscriptionRequestPhase.parkedOnServer(exit)
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

        let cancelled = try #require(RemoteTranscriptionStatusPresentation.make(phase: .cancelled))
        #expect(cancelled.isTerminalFailure)
        #expect(!cancelled.offersRetry)
        #expect(!cancelled.offersResume)
    }
}
