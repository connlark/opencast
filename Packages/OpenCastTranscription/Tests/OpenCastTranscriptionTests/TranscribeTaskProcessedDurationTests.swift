import Foundation
import Testing
@preconcurrency import WhisperKit

@Suite("TranscribeTask processed duration")
struct TranscribeTaskProcessedDurationTests {
    private func makeTask() -> TranscribeTask {
        TranscribeTask(
            currentTimings: TranscriptionTimings(),
            progress: nil,
            audioEncoder: StubAudioEncoding(),
            featureExtractor: StubFeatureExtracting(),
            segmentSeeker: StubSegmentSeeking(),
            textDecoder: ScriptedTextDecoding(fallbackScript: []),
            tokenizer: StubWhisperTokenizer()
        )
    }

    private func makeOptions(clipTimestamps: [Float]) -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: "en",
            temperature: 0,
            temperatureFallbackCount: 0,
            sampleLength: 8,
            usePrefillPrompt: false,
            detectLanguage: false,
            skipSpecialTokens: true,
            clipTimestamps: clipTimestamps,
            windowClipTime: 0,
            concurrentWorkerCount: 1
        )
    }

    @Test("Unclipped runs report the full audio duration")
    func unclippedRunsReportFullAudioDuration() async throws {
        let result = try await makeTask().run(
            audioArray: [Float](repeating: 0.1, count: 48000),
            decodeOptions: makeOptions(clipTimestamps: []),
            callback: nil
        )

        #expect(result.timings.inputAudioSeconds == 3.0)
    }

    @Test("Start-only clips report the remaining duration")
    func startOnlyClipsReportRemainingDuration() async throws {
        let result = try await makeTask().run(
            audioArray: [Float](repeating: 0.1, count: 48000),
            decodeOptions: makeOptions(clipTimestamps: [1]),
            callback: nil
        )

        #expect(result.timings.inputAudioSeconds == 2.0)
    }

    @Test("Bounded clip windows report only the decoded range")
    func boundedClipWindowsReportOnlyDecodedRange() async throws {
        let result = try await makeTask().run(
            audioArray: [Float](repeating: 0.1, count: 48000),
            decodeOptions: makeOptions(clipTimestamps: [1, 2]),
            callback: nil
        )

        #expect(result.timings.inputAudioSeconds == 1.0)
    }

}
