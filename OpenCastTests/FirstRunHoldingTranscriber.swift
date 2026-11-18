import Foundation
import OpenCastTranscription
@testable import OpenCast

/// Holds the first `heldRunCount` runs open until they are cancelled or the
/// test finishes the latest one; every later run completes at once.
final class FirstRunHoldingTranscriber: EpisodeTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private let heldRunCount: Int
    private var storedRequests: [EpisodeTranscriptionRunRequest] = []
    private var isDrainRetentionOpen = false
    private var storedDrainRetentionAtRequests: [Bool] = []
    private var held: (
        continuation: AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error>.Continuation,
        request: EpisodeTranscriptionRunRequest
    )?

    init(heldRunCount: Int) {
        self.heldRunCount = heldRunCount
    }

    var requestCount: Int {
        lock.withLock { storedRequests.count }
    }

    /// Whether a queue drain's model retention was open at each request.
    var drainRetentionAtRequests: [Bool] {
        lock.withLock { storedDrainRetentionAtRequests }
    }

    func beginDrainRetention() {
        lock.withLock { isDrainRetentionOpen = true }
    }

    func endDrainRetention() async {
        lock.withLock { isDrainRetentionOpen = false }
    }

    func transcribe(
        _ request: EpisodeTranscriptionRunRequest
    ) -> AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error> {
        let holds = lock.withLock {
            storedRequests.append(request)
            storedDrainRetentionAtRequests.append(isDrainRetentionOpen)
            return storedRequests.count <= heldRunCount
        }
        guard holds else {
            return AsyncThrowingStream { continuation in
                Self.complete(request, on: continuation)
            }
        }
        return AsyncThrowingStream { continuation in
            lock.withLock { held = (continuation, request) }
        }
    }

    /// Completes the latest held run, if it is still open.
    func finishHeldRun() {
        guard let held = lock.withLock({ held }) else {
            return
        }
        Self.complete(held.request, on: held.continuation)
    }

    func unload() async {
    }

    private static func complete(
        _ request: EpisodeTranscriptionRunRequest,
        on continuation: AsyncThrowingStream<EpisodeTranscriptionRunEvent, Error>.Continuation
    ) {
        let start = request.resumeStart ?? 0
        let segments = [
            OpenCastTranscriptSegment(
                id: 0,
                start: start,
                end: start + 2,
                text: "held transcript",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            ),
            OpenCastTranscriptSegment(
                id: 1,
                start: start + 2,
                end: start + 4,
                text: "brought to you by tests",
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            )
        ]
        continuation.yield(.finished(OpenCastTranscriptionResult(
            modelIdentifier: request.modelIdentifier,
            languageCode: request.languageCode,
            text: segments.map(\.text).joined(separator: " "),
            segments: segments,
            timings: OpenCastTranscriptionTimings(
                audioDuration: 60,
                modelLoading: 0.1,
                audioLoading: 0.1,
                transcription: 0.2,
                fullPipeline: 0.4,
                realTimeFactor: 0.01,
                decodingFallbackCount: 0,
                decodingFallback: 0,
                decodingWindowCount: 1
            )
        )))
        continuation.finish()
    }
}
