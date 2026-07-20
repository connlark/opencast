import Foundation
@preconcurrency import WhisperKit

final class OpenCastLongFormTranscriptionEventEmitter: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncThrowingStream<OpenCastLongFormTranscriptionEvent, Error>.Continuation
    private let audioDuration: TimeInterval
    private let segmentMapper: @Sendable (TranscriptionSegment, Int) -> OpenCastTranscriptSegment
    private var segments: [OpenCastTranscriptSegment] = []
    private var transcriptText = ""
    private var checkpointIndex = 0
    private var nextSegmentID = 0
    private var completedDuration: TimeInterval
    private var hasYieldedProgress = false
    private var lastYieldedProgressCompletedDuration: TimeInterval = -1
    private var lastYieldedProgressCheckpointCount = -1
    private var lastYieldedProgressWindowIndex: Int?

    init(
        continuation: AsyncThrowingStream<OpenCastLongFormTranscriptionEvent, Error>.Continuation,
        audioDuration: TimeInterval,
        resumeStart: TimeInterval,
        segmentMapper: @escaping @Sendable (TranscriptionSegment, Int) -> OpenCastTranscriptSegment
    ) {
        self.continuation = continuation
        self.audioDuration = audioDuration
        completedDuration = resumeStart
        self.segmentMapper = segmentMapper
    }

    func yieldInitialProgress() {
        yieldProgress(currentWindowIndex: nil, currentText: nil, force: true)
    }

    func handleWindowStart(_ windowIndex: Int) {
        yieldProgress(currentWindowIndex: windowIndex, currentText: nil, force: false)
    }

    func handleSegments(_ discoveredSegments: [TranscriptionSegment]) {
        let checkpoint: OpenCastLongFormTranscriptionCheckpoint? = lock.withLock {
            let mappedSegments = discoveredSegments
                .map { segment in
                    let mapped = segmentMapper(segment, nextSegmentID)
                    nextSegmentID += 1
                    return mapped
                }
                .filter { !$0.text.isEmpty }

            guard !mappedSegments.isEmpty else {
                return nil
            }

            for segment in mappedSegments {
                if !transcriptText.isEmpty {
                    transcriptText.append(" ")
                }
                transcriptText.append(segment.text)
            }
            segments.append(contentsOf: mappedSegments)
            completedDuration = max(completedDuration, mappedSegments.map(\.end).max() ?? completedDuration)
            checkpointIndex += 1
            return OpenCastLongFormTranscriptionCheckpoint(
                index: checkpointIndex,
                audioDuration: audioDuration,
                completedDuration: min(completedDuration, audioDuration),
                segments: segments,
                text: transcriptText
            )
        }

        guard let checkpoint else {
            return
        }

        continuation.yield(.checkpoint(checkpoint))
        continuation.yield(.progress(OpenCastLongFormTranscriptionProgress(
            audioDuration: audioDuration,
            completedDuration: checkpoint.completedDuration,
            checkpointCount: checkpoint.index
        )))
    }

    private func yieldProgress(currentWindowIndex: Int?, currentText: String?, force: Bool) {
        let progress: OpenCastLongFormTranscriptionProgress? = lock.withLock {
            let progress = OpenCastLongFormTranscriptionProgress(
                audioDuration: audioDuration,
                completedDuration: min(completedDuration, audioDuration),
                checkpointCount: checkpointIndex,
                currentWindowIndex: currentWindowIndex,
                currentText: currentText?.isEmpty == true ? nil : currentText
            )

            guard force || shouldYieldProgress(progress) else {
                return nil
            }

            hasYieldedProgress = true
            lastYieldedProgressCompletedDuration = progress.completedDuration
            lastYieldedProgressCheckpointCount = progress.checkpointCount
            lastYieldedProgressWindowIndex = progress.currentWindowIndex
            return progress
        }

        if let progress {
            continuation.yield(.progress(progress))
        }
    }

    private func shouldYieldProgress(_ progress: OpenCastLongFormTranscriptionProgress) -> Bool {
        !hasYieldedProgress
            || progress.completedDuration != lastYieldedProgressCompletedDuration
            || progress.checkpointCount != lastYieldedProgressCheckpointCount
            || progress.currentWindowIndex != lastYieldedProgressWindowIndex
    }
}

private extension NSLock {
    func withLock<Result>(_ work: () -> Result) -> Result {
        lock()
        defer {
            unlock()
        }
        return work()
    }
}
