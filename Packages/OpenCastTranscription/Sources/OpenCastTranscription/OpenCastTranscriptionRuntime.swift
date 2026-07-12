@preconcurrency import WhisperKit

protocol OpenCastTranscriptionRuntime: Sendable {
    func transcribe(
        audioArray: [Float],
        decodeOptions: DecodingOptions,
        callback: TranscriptionCallback?,
        windowCallback: WindowStartCallback?,
        segmentCallback: SegmentDiscoveryCallback?
    ) async throws -> [TranscriptionResult]
    func unloadModels() async
}
