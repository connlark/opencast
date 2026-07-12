import Foundation
@preconcurrency import WhisperKit

struct AudioProcessorTranscriptionAudioLoader: OpenCastTranscriptionAudioLoading {
    func samples(from audioFileURL: URL, clipStart: TimeInterval, clipDuration: TimeInterval?) async throws -> [Float] {
        try await Self.loadSamples(
            from: audioFileURL,
            clipStart: clipStart,
            clipDuration: clipDuration
        )
    }

    @concurrent
    private nonisolated static func loadSamples(
        from audioFileURL: URL,
        clipStart: TimeInterval,
        clipDuration: TimeInterval?
    ) async throws -> [Float] {
        try Task.checkCancellation()
        let endTime = clipDuration.map { clipStart + $0 }
        let samples = try AudioProcessor.loadAudioAsFloatArray(
            fromPath: audioFileURL.path,
            channelMode: .sumChannels(nil),
            startTime: clipStart,
            endTime: endTime
        )
        try Task.checkCancellation()
        return samples
    }
}
