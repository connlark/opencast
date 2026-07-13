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

    func spillSamples(
        from audioFileURL: URL,
        clipStart: TimeInterval,
        clipDuration: TimeInterval?,
        to destination: URL
    ) async throws -> Int {
        try await Self.spill(
            from: audioFileURL,
            clipStart: clipStart,
            clipDuration: clipDuration,
            to: destination
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

    @concurrent
    private nonisolated static func spill(
        from audioFileURL: URL,
        clipStart: TimeInterval,
        clipDuration: TimeInterval?,
        to destination: URL
    ) async throws -> Int {
        try Task.checkCancellation()
        let endTime = clipDuration.map { clipStart + $0 }
        let sampleCount = try AudioProcessor.spillAudioToPCMFile(
            fromPath: audioFileURL.path,
            channelMode: .sumChannels(nil),
            startTime: clipStart,
            endTime: endTime,
            to: destination
        )
        try Task.checkCancellation()
        return sampleCount
    }
}
