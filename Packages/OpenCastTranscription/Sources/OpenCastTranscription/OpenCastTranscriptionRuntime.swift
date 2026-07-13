@preconcurrency import WhisperKit

protocol OpenCastTranscriptionRuntime: Sendable {
    func transcribe(
        audioArray: [Float],
        decodeOptions: DecodingOptions,
        callback: TranscriptionCallback?,
        windowCallback: WindowStartCallback?,
        segmentCallback: SegmentDiscoveryCallback?
    ) async throws -> [TranscriptionResult]

    /// Whisper-perf G2: bounded-memory long-form decode from a sample source.
    func transcribe(
        audioSource: any AudioSampleSource,
        decodeOptions: DecodingOptions,
        callback: TranscriptionCallback?,
        windowCallback: WindowStartCallback?,
        segmentCallback: SegmentDiscoveryCallback?
    ) async throws -> [TranscriptionResult]

    func unloadModels() async
}
