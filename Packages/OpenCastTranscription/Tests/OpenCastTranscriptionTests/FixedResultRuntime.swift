@testable import OpenCastTranscription
@preconcurrency import WhisperKit

/// Returns a canned WhisperKit result so tests can assert timing export mapping.
struct FixedResultRuntime: OpenCastTranscriptionRuntime {
    let result: TranscriptionResult

    func transcribe(
        audioArray: [Float],
        decodeOptions: DecodingOptions,
        callback: TranscriptionCallback?,
        windowCallback: WindowStartCallback?,
        segmentCallback: SegmentDiscoveryCallback?
    ) async throws -> [TranscriptionResult] {
        [result]
    }

    func transcribe(
        audioSource: any AudioSampleSource,
        decodeOptions: DecodingOptions,
        callback: TranscriptionCallback?,
        windowCallback: WindowStartCallback?,
        segmentCallback: SegmentDiscoveryCallback?
    ) async throws -> [TranscriptionResult] {
        [result]
    }

    func unloadModels() async {}
}
