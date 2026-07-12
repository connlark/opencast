import CoreML
import Foundation
@preconcurrency import WhisperKit

/// TextDecoding stub whose decodeText attempts fall back according to a
/// per-call script. Invokes the provided callback once per attempt so tests
/// can observe the windowId that TranscribeTask injects.
final class ScriptedTextDecoding: TextDecoding, @unchecked Sendable {
    var tokenizer: (any WhisperTokenizer)?
    var isModelMultilingual = false
    let supportsWordTimestamps = false
    let logitsSize: Int? = 16
    var logitsFilters: [any LogitsFiltering]?
    let kvCacheEmbedDim: Int? = 4
    let kvCacheMaxSequenceLength: Int? = 8
    let windowSize: Int? = 4
    let embedSize: Int? = 4

    private let lock = NSLock()
    private let fallbackScript: [Bool]
    private var decodeCallCount = 0
    private var _receivedCallbackPresence: [Bool] = []

    init(fallbackScript: [Bool]) {
        self.fallbackScript = fallbackScript
    }

    var receivedCallbackPresence: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return _receivedCallbackPresence
    }

    private func nextCallIndex(callbackPresent: Bool) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let index = decodeCallCount
        decodeCallCount += 1
        _receivedCallbackPresence.append(callbackPresent)
        return index
    }

    func predictLogits(_ inputs: any TextDecoderInputType) async throws -> (any TextDecoderOutputType)? {
        nil
    }

    func decodeText(
        from encoderOutput: any AudioEncoderOutputType,
        using decoderInputs: any DecodingInputsType,
        sampler tokenSampler: any TokenSampling,
        options decoderOptions: DecodingOptions,
        callback: TranscriptionCallback?
    ) async throws -> DecodingResult {
        let callIndex = nextCallIndex(callbackPresent: callback != nil)

        _ = callback?(TranscriptionProgress(
            timings: TranscriptionTimings(),
            text: " stub",
            tokens: [1]
        ))

        let needsFallback = callIndex < fallbackScript.count && fallbackScript[callIndex]
        return DecodingResult(
            language: "en",
            languageProbs: [:],
            tokens: [1],
            tokenLogProbs: [[1: -0.1]],
            text: " stub",
            avgLogProb: -0.1,
            noSpeechProb: 0,
            temperature: 0,
            compressionRatio: 1,
            cache: nil,
            timings: TranscriptionTimings(),
            fallback: DecodingFallback(needsFallback: needsFallback, fallbackReason: needsFallback ? "logProbThreshold" : "none")
        )
    }

    func detectLanguage(
        from encoderOutput: any AudioEncoderOutputType,
        using decoderInputs: any DecodingInputsType,
        sampler tokenSampler: any TokenSampling,
        options: DecodingOptions,
        temperature: FloatType
    ) async throws -> DecodingResult {
        .emptyResults
    }

    static func updateKVCache(
        keyTensor: MLMultiArray,
        keySlice: MLMultiArray,
        valueTensor: MLMultiArray,
        valueSlice: MLMultiArray,
        insertAtIndex index: Int
    ) {}
}
