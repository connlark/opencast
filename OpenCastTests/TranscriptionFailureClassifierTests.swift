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
