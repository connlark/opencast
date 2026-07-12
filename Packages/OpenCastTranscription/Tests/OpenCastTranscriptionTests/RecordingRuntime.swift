@testable import OpenCastTranscription
import WhisperKit

actor RecordingRuntime: OpenCastTranscriptionRuntime {
    private let modelIdentifier: String
    private let log: TranscriptionEventLog
    private let decodeDelay: Duration
    private var activeDecodeCount = 0
    private var _maxActiveDecodeCount = 0
    private var _decodeCount = 0

    init(
        modelIdentifier: String,
        log: TranscriptionEventLog,
        decodeDelay: Duration = .milliseconds(10)
    ) {
        self.modelIdentifier = modelIdentifier
        self.log = log
        self.decodeDelay = decodeDelay
    }

    var maxActiveDecodeCount: Int {
        _maxActiveDecodeCount
    }

    var decodeCount: Int {
        _decodeCount
    }

    func transcribe(
        audioArray: [Float],
        decodeOptions: DecodingOptions,
        callback: TranscriptionCallback?,
        windowCallback: WindowStartCallback?,
        segmentCallback: SegmentDiscoveryCallback?
    ) async throws -> [TranscriptionResult] {
        activeDecodeCount += 1
        _maxActiveDecodeCount = max(_maxActiveDecodeCount, activeDecodeCount)
        _decodeCount += 1
        let decodeNumber = _decodeCount
        await log.append("decode-start:\(modelIdentifier):\(decodeNumber)")

        do {
            try await Task.sleep(for: decodeDelay)
            try Task.checkCancellation()
            let segment = TranscriptionSegment(
                start: Float(decodeOptions.clipTimestamps.first ?? 0),
                end: Float(decodeOptions.clipTimestamps.first ?? 0) + 1,
                text: " hello"
            )
            windowCallback?(decodeNumber - 1)
            segmentCallback?([segment])
            _ = callback?(TranscriptionProgress(
                timings: TranscriptionTimings(),
                text: " hello",
                tokens: [1],
                windowId: decodeNumber - 1
            ))
            activeDecodeCount -= 1
            await log.append("decode-end:\(modelIdentifier):\(decodeNumber)")
            return [
                TranscriptionResult(
                    text: " hello",
                    segments: [segment],
                    language: "model-reported",
                    timings: TranscriptionTimings()
                )
            ]
        } catch {
            activeDecodeCount -= 1
            await log.append("decode-cancel:\(modelIdentifier):\(decodeNumber)")
            throw error
        }
    }

    func unloadModels() async {
        await log.append("unload:\(modelIdentifier)")
    }
}
