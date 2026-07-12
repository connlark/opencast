import Foundation
import OpenCastTranscription

nonisolated struct EpisodeTranscriptTimings: Codable, Sendable, Equatable {
    var modelLoading: TimeInterval
    var audioLoading: TimeInterval
    var transcription: TimeInterval
    var fullPipeline: TimeInterval
    var realTimeFactor: Double
    var decodingFallbackCount: Int
    var decodingFallback: TimeInterval
    var decodingWindowCount: Int

    init(resultTimings: OpenCastTranscriptionTimings = OpenCastTranscriptionTimings(
        audioDuration: 0,
        modelLoading: 0,
        audioLoading: 0,
        transcription: 0,
        fullPipeline: 0,
        realTimeFactor: 0
    )) {
        modelLoading = resultTimings.modelLoading
        audioLoading = resultTimings.audioLoading
        transcription = resultTimings.transcription
        fullPipeline = resultTimings.fullPipeline
        realTimeFactor = resultTimings.realTimeFactor
        decodingFallbackCount = resultTimings.decodingFallbackCount
        decodingFallback = resultTimings.decodingFallback
        decodingWindowCount = resultTimings.decodingWindowCount
    }
}
