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

    @Test(
        "Processed duration counts only the decoded clip range",
        arguments: zip([[], [1], [1, 2]] as [[Float]], [3.0, 2.0, 1.0])
    )
    func processedDurationCountsOnlyTheDecodedClipRange(clipTimestamps: [Float], expectedSeconds: Double) async throws {
        let result = try await makeTask().run(
            audioArray: [Float](repeating: 0.1, count: 48000),
            decodeOptions: makeOptions(clipTimestamps: clipTimestamps),
            callback: nil
        )

        #expect(result.timings.inputAudioSeconds == expectedSeconds)
    }
}
