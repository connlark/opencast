@preconcurrency import WhisperKit

// Access to the mutable WhisperKit instance is serialized by OpenCastTranscriptionService.
final class WhisperKitTranscriptionRuntime: @unchecked Sendable, OpenCastTranscriptionRuntime {
    private let runtime: WhisperKit

    init(runtime: WhisperKit) {
        self.runtime = runtime
    }

    func transcribe(
        audioArray: [Float],
        decodeOptions: DecodingOptions,
        callback: TranscriptionCallback?,
        windowCallback: WindowStartCallback?,
        segmentCallback: SegmentDiscoveryCallback?
    ) async throws -> [TranscriptionResult] {
        try await runtime.transcribe(
            audioArray: audioArray,
            decodeOptions: decodeOptions,
            callback: callback,
            windowCallback: windowCallback,
            segmentCallback: segmentCallback
        )
    }

    func transcribe(
        audioSource: any AudioSampleSource,
        decodeOptions: DecodingOptions,
        callback: TranscriptionCallback?,
        windowCallback: WindowStartCallback?,
        segmentCallback: SegmentDiscoveryCallback?
    ) async throws -> [TranscriptionResult] {
        try await runtime.transcribe(
            audioSource: audioSource,
            decodeOptions: decodeOptions,
            callback: callback,
            windowCallback: windowCallback,
            segmentCallback: segmentCallback
        )
    }

    func unloadModels() async {
        await runtime.unloadModels()
    }
}
