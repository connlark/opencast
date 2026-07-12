@testable import OpenCastTranscription
@preconcurrency import WhisperKit

struct FixedResultRuntimeLoader: OpenCastTranscriptionRuntimeLoading {
    let result: TranscriptionResult

    func loadRuntime(for location: OpenCastWhisperModelLocation) async throws -> any OpenCastTranscriptionRuntime {
        FixedResultRuntime(result: result)
    }
}
