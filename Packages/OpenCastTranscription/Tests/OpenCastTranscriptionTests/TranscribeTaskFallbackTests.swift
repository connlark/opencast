import Foundation
import Testing
@preconcurrency import WhisperKit

@Suite("TranscribeTask fallback accounting")
struct TranscribeTaskFallbackTests {
    /// 3 seconds of audio with 1-second stub windows: three decode windows.
    private static let threeWindowAudio = [Float](repeating: 0.1, count: 48000)

    private final class WindowIdLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [Int] = []

        var values: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return _values
        }

        func append(_ value: Int) {
            lock.lock()
            _values.append(value)
            lock.unlock()
        }
    }

    private func makeTask(fallbackScript: [Bool]) -> (task: TranscribeTask, decoder: ScriptedTextDecoding) {
        let decoder = ScriptedTextDecoding(fallbackScript: fallbackScript)
        let task = TranscribeTask(
            currentTimings: TranscriptionTimings(),
            progress: nil,
            audioEncoder: StubAudioEncoding(),
            featureExtractor: StubFeatureExtracting(),
            segmentSeeker: StubSegmentSeeking(),
            textDecoder: decoder,
            tokenizer: StubWhisperTokenizer()
        )
        return (task, decoder)
    }

    private func makeOptions() -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: "en",
            temperature: 0,
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: 3,
            sampleLength: 8,
            usePrefillPrompt: false,
            detectLanguage: false,
            skipSpecialTokens: true,
            windowClipTime: 0,
            concurrentWorkerCount: 1
        )
    }

    @Test("Windows without fallbacks record zero fallbacks and honest window ids")
    func windowsWithoutFallbacksRecordZeroFallbacks() async throws {
        let log = WindowIdLog()
        let (task, _) = makeTask(fallbackScript: [false, false, false])

        let result = try await task.run(
            audioArray: Self.threeWindowAudio,
            decodeOptions: makeOptions(),
            callback: { progress in
                log.append(progress.windowId)
                return true
            }
        )

        #expect(result.timings.totalDecodingFallbacks == 0)
        #expect(result.timings.totalDecodingWindows == 3)
        #expect(log.values == [0, 1, 2])
    }

    @Test("A single first fallback is counted as one, not zero")
    func singleFirstFallbackCountsAsOne() async throws {
        let log = WindowIdLog()
        let (task, _) = makeTask(fallbackScript: [true, false, false, false])

        let result = try await task.run(
            audioArray: Self.threeWindowAudio,
            decodeOptions: makeOptions(),
            callback: { progress in
                log.append(progress.windowId)
                return true
            }
        )

        #expect(result.timings.totalDecodingFallbacks == 1)
        #expect(result.timings.totalDecodingWindows == 3)
        #expect(log.values == [0, 0, 1, 2])
    }

    @Test("Fallbacks accumulate across windows without shifting window ids")
    func fallbacksAccumulateAcrossWindows() async throws {
        let log = WindowIdLog()
        // Window 0 falls back twice, window 1 once, window 2 none.
        let (task, _) = makeTask(fallbackScript: [true, true, false, true, false, false])

        let result = try await task.run(
            audioArray: Self.threeWindowAudio,
            decodeOptions: makeOptions(),
            callback: { progress in
                log.append(progress.windowId)
                return true
            }
        )

        #expect(result.timings.totalDecodingFallbacks == 3)
        #expect(result.timings.totalDecodingWindows == 3)
        #expect(log.values == [0, 0, 0, 1, 1, 2])
    }

    @Test("Window start signal fires once per window even through fallbacks")
    func windowStartSignalFiresOncePerWindow() async throws {
        let log = WindowIdLog()
        let (task, decoder) = makeTask(fallbackScript: [true, true, false, true, false, false])
        task.windowStartCallback = { windowIndex in
            log.append(windowIndex)
        }

        let result = try await task.run(
            audioArray: Self.threeWindowAudio,
            decodeOptions: makeOptions(),
            callback: nil
        )

        #expect(result.timings.totalDecodingWindows == 3)
        #expect(log.values == [0, 1, 2])
        #expect(decoder.receivedCallbackPresence == [Bool](repeating: false, count: 6))
    }

    @Test("Nil callbacks reach the decoder as nil instead of a wrapper")
    func nilCallbacksReachDecoderAsNil() async throws {
        let (task, decoder) = makeTask(fallbackScript: [false, false, false])

        _ = try await task.run(
            audioArray: Self.threeWindowAudio,
            decodeOptions: makeOptions(),
            callback: nil
        )

        #expect(decoder.receivedCallbackPresence == [false, false, false])
    }

    @Test("Provided callbacks still reach the decoder wrapped with window ids")
    func providedCallbacksStillReachDecoder() async throws {
        let log = WindowIdLog()
        let (task, decoder) = makeTask(fallbackScript: [false, false, false])

        _ = try await task.run(
            audioArray: Self.threeWindowAudio,
            decodeOptions: makeOptions(),
            callback: { progress in
                log.append(progress.windowId)
                return true
            }
        )

        #expect(decoder.receivedCallbackPresence == [true, true, true])
        #expect(log.values == [0, 1, 2])
    }

    @Test("Fallbacks exhausting all temperatures keep the final attempt count")
    func fallbacksExhaustingAllTemperaturesKeepFinalAttemptCount() async throws {
        // Window 0 falls back on every one of its four attempts; windows 1-2 clean.
        let (task, _) = makeTask(fallbackScript: [true, true, true, true, false, false])

        let result = try await task.run(
            audioArray: Self.threeWindowAudio,
            decodeOptions: makeOptions(),
            callback: nil
        )

        #expect(result.timings.totalDecodingFallbacks == 4)
        #expect(result.timings.totalDecodingWindows == 3)
    }
}
