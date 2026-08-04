import Foundation
import Testing
@testable import OpenCast

@Suite("Background remote-transcription upload transport")
struct BackgroundRemoteTranscriptionUploadTransportTests {
    @Test("A displaced part continuation fails visibly instead of hanging")
    func displacedPartContinuationFailsVisibly() async throws {
        let transport = BackgroundRemoteTranscriptionUploadTransport(
            jobID: "displaced-\(UUID().uuidString)"
        )

        let (registeredFirst, registeredFirstContinuation) = AsyncStream<Void>.makeStream()
        let firstWaiter = Task<RemoteTranscriptionUploadPartPutResult, any Error> {
            try await withCheckedThrowingContinuation { first in
                transport.register(first, partNumber: 7)
                registeredFirstContinuation.finish()
            }
        }
        for await _ in registeredFirst {}

        let secondWaiter = Task<RemoteTranscriptionUploadPartPutResult, any Error> {
            try await withCheckedThrowingContinuation { second in
                transport.register(second, partNumber: 7)
            }
        }

        // The displaced first waiter must resume with the typed error rather
        // than hang forever behind the silent overwrite.
        await #expect(throws: BackgroundRemoteTranscriptionUploadTransport.WaiterDisplaced.self) {
            _ = try await firstWaiter.value
        }

        // Drain the second waiter so no continuation leaks out of the test.
        transport.take(partNumber: 7)?.resume(throwing: CancellationError())
        _ = try? await secondWaiter.value
        transport.finishTasksAndInvalidate()
    }
}
