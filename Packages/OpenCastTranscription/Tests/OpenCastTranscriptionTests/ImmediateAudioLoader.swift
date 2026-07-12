import Foundation
@testable import OpenCastTranscription

struct ImmediateAudioLoader: OpenCastTranscriptionAudioLoading {
    var samples: [Float]

    func samples(
        from audioFileURL: URL,
        clipStart: TimeInterval,
        clipDuration: TimeInterval?
    ) async throws -> [Float] {
        try Task.checkCancellation()
        return samples
    }
}
