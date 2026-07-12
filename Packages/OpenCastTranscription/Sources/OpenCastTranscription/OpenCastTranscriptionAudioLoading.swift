import Foundation

protocol OpenCastTranscriptionAudioLoading: Sendable {
    func samples(from audioFileURL: URL, clipStart: TimeInterval, clipDuration: TimeInterval?) async throws -> [Float]
}
