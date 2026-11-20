import Foundation

protocol OpenCastTranscriptionAudioLoading: Sendable {
    func samples(from audioFileURL: URL, clipStart: TimeInterval, clipDuration: TimeInterval?) async throws -> [Float]

    /// Writes the canonical 16 kHz mono Float32 PCM to `destination` instead of keeping it
    /// resident, and returns the sample count.
    func spillSamples(from audioFileURL: URL, clipStart: TimeInterval, clipDuration: TimeInterval?, to destination: URL) async throws -> Int
}

extension OpenCastTranscriptionAudioLoading {
    /// Holds the whole episode in memory before writing; a production loader streams instead.
    func spillSamples(from audioFileURL: URL, clipStart: TimeInterval, clipDuration: TimeInterval?, to destination: URL) async throws -> Int {
        let samples = try await samples(from: audioFileURL, clipStart: clipStart, clipDuration: clipDuration)
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: destination)
        return samples.count
    }
}
