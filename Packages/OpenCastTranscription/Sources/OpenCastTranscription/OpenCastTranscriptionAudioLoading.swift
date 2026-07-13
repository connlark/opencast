import Foundation

protocol OpenCastTranscriptionAudioLoading: Sendable {
    func samples(from audioFileURL: URL, clipStart: TimeInterval, clipDuration: TimeInterval?) async throws -> [Float]

    /// Whisper-perf G2: the same decode pass as `samples`, but the canonical
    /// 16 kHz mono Float32 PCM spills to `destination` instead of staying
    /// resident. Returns the spilled sample count.
    func spillSamples(from audioFileURL: URL, clipStart: TimeInterval, clipDuration: TimeInterval?, to destination: URL) async throws -> Int
}

extension OpenCastTranscriptionAudioLoading {
    /// Default used by test loaders: materialize, then write. The production
    /// loader streams chunk-by-chunk without materializing the episode.
    func spillSamples(from audioFileURL: URL, clipStart: TimeInterval, clipDuration: TimeInterval?, to destination: URL) async throws -> Int {
        let samples = try await samples(from: audioFileURL, clipStart: clipStart, clipDuration: clipDuration)
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: destination)
        return samples.count
    }
}
