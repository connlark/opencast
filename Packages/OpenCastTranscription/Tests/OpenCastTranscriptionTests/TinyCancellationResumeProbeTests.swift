import Foundation
import Testing
@testable import OpenCastTranscription
@preconcurrency import WhisperKit

/// Opt-in real-model gate for the exact-output stack: cancel after the
/// first durable checkpoint, resume from it, and verify the stitched segments
/// cover the clip with no gaps or duplicates. Requires the local Tiny model:
/// OPENCAST_TINY_RESUME_PROBE=1 OPENCAST_TRANSCRIPTION_AUDIO=<file>.
@Suite("Tiny cancellation and resume probe")
struct TinyCancellationResumeProbeTests {
    @Test(
        "Cancel after a checkpoint, resume, and stitch without gaps or duplicates",
        .enabled(if: ProcessInfo.processInfo.environment["OPENCAST_TINY_RESUME_PROBE"] == "1"
            && ProcessInfo.processInfo.environment["OPENCAST_TRANSCRIPTION_AUDIO"] != nil)
    )
    func cancelResumeStitch() async throws {
        let audioPath = try #require(ProcessInfo.processInfo.environment["OPENCAST_TRANSCRIPTION_AUDIO"])

        let clipEnd: TimeInterval = 120
        let audioURL = URL(fileURLWithPath: audioPath)
        let service = OpenCastTranscriptionService(modelLocator: DownloadedWhisperModelLocator(model: .tinyEnglish))

        func request(resumeStart: TimeInterval?) -> OpenCastLongFormTranscriptionRequest {
            OpenCastLongFormTranscriptionRequest(
                audioFileURL: audioURL,
                resumeStart: resumeStart,
                clipEnd: clipEnd,
                sourceAudioURL: audioURL.absoluteString,
                sourceFileByteCount: 0,
                sourceFileSHA256: "probe",
                modelIdentifier: OpenCastWhisperModel.tinyEnglish.rawValue,
                modelVersion: OpenCastWhisperModel.tinyEnglish.defaultRemoteVersion,
                modelTreeSHA256: "probe"
            )
        }

        // Interrupted run: stop consuming after the first checkpoint, which
        // cancels the underlying task mid-transcription.
        var interruptedCheckpoint: OpenCastLongFormTranscriptionCheckpoint?
        for try await event in await service.transcribe(request(resumeStart: nil)) {
            if case .checkpoint(let checkpoint) = event {
                interruptedCheckpoint = checkpoint
                break
            }
        }
        let checkpoint = try #require(interruptedCheckpoint)
        #expect(checkpoint.completedDuration > 0)
        #expect(checkpoint.completedDuration < clipEnd)

        // Resumed run: service must still be usable after the cancellation.
        var resumedResult: OpenCastTranscriptionResult?
        for try await event in await service.transcribe(request(resumeStart: checkpoint.completedDuration)) {
            if case .finished(let result) = event {
                resumedResult = result
            }
        }
        await service.unload()
        let resumed = try #require(resumedResult)
        #expect(abs(resumed.timings.processedAudioDuration - (clipEnd - checkpoint.completedDuration)) < 1.0)

        // Stitch checkpoint segments with resumed segments and check coverage.
        let stitched = checkpoint.segments + resumed.segments
        #expect(!stitched.isEmpty)
        var previousEnd = stitched.first?.start ?? 0
        var maxGap = 0.0
        var maxOverlap = 0.0
        for segment in stitched {
            maxGap = max(maxGap, segment.start - previousEnd)
            maxOverlap = max(maxOverlap, previousEnd - segment.start)
            previousEnd = max(previousEnd, segment.end)
        }
        print("TINY_RESUME_PROBE checkpointAt=\(checkpoint.completedDuration) stitched=\(stitched.count) maxGap=\(maxGap) maxOverlap=\(maxOverlap) lastEnd=\(previousEnd)")
        #expect(maxGap < 3.0, "no gaps beyond a segment boundary tolerance")
        #expect(maxOverlap < 0.75, "no duplicated audio beyond boundary tolerance")
        #expect(previousEnd >= clipEnd - 3.0, "stitched output reaches the clip end")
    }
}
