import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Transcription failure classifier")
struct TranscriptionFailureClassifierTests {
    @Test("CoreML and Espresso domains are environmental only when constrained")
    func computeDomainsRequireConstrainedEnvironment() {
        let background = EpisodeTranscriptionFailureEnvironment(
            sceneState: .background,
            isProtectedDataAvailable: true
        )
        let locked = EpisodeTranscriptionFailureEnvironment(
            sceneState: .active,
            isProtectedDataAvailable: false
        )

        #expect(classify(domain: "com.apple.CoreML", environment: background) == .environmentalCompute)
        #expect(classify(domain: "com.apple.Espresso", environment: background) == .environmentalCompute)
        #expect(classify(domain: "com.apple.appleneuralengine", environment: locked) == .environmentalCompute)
        #expect(classify(domain: "com.apple.CoreML", environment: .foreground) == .failed)
    }

    @Test("Cancellation-shaped NSErrors classify as cancelled")
    func cancellationErrorsClassifyAsCancelled() {
        let background = EpisodeTranscriptionFailureEnvironment(
            sceneState: .background,
            isProtectedDataAvailable: true
        )

        #expect(TranscriptionFailureClassifier.classify(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
            environment: background
        ) == .cancelled)
        #expect(TranscriptionFailureClassifier.classify(
            NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.userCancelled.rawValue),
            environment: background
        ) == .cancelled)
        #expect(TranscriptionFailureClassifier.classify(
            NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ECANCELED.rawValue)),
            environment: background
        ) == .cancelled)
    }

    @Test("Unknown background errors remain failed")
    func unknownDomainsRemainFailed() {
        let background = EpisodeTranscriptionFailureEnvironment(
            sceneState: .background,
            isProtectedDataAvailable: true
        )

        #expect(classify(domain: "example.unknown", environment: background) == .failed)
    }

    @Test("Disk exhaustion is an environmental storage interrupt in any scene state")
    func diskExhaustionClassifiesAsEnvironmentalStorage() {
        let background = EpisodeTranscriptionFailureEnvironment(
            sceneState: .background,
            isProtectedDataAvailable: true
        )

        // The spill's FileHandle.write throws NSFileWriteOutOfSpaceError with
        // an underlying POSIX ENOSPC; both shapes must classify, and the
        // classification must not depend on a constrained environment.
        let outOfSpace = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.Code.fileWriteOutOfSpace.rawValue
        )
        let posixFull = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(POSIXErrorCode.ENOSPC.rawValue)
        )
        let wrapped = NSError(
            domain: "WhisperKit.WhisperError",
            code: 5,
            userInfo: [NSUnderlyingErrorKey: posixFull]
        )

        #expect(TranscriptionFailureClassifier.classify(outOfSpace, environment: background) == .environmentalStorage)
        #expect(TranscriptionFailureClassifier.classify(outOfSpace, environment: .foreground) == .environmentalStorage)
        #expect(TranscriptionFailureClassifier.classify(posixFull, environment: background) == .environmentalStorage)
        #expect(TranscriptionFailureClassifier.classify(wrapped, environment: .foreground) == .environmentalStorage)
    }

    private func classify(
        domain: String,
        environment: EpisodeTranscriptionFailureEnvironment
    ) -> TranscriptionFailureClassification {
        TranscriptionFailureClassifier.classify(
            NSError(domain: domain, code: 0),
            environment: environment
        )
    }
}
