import Foundation
import OpenCastTranscription

nonisolated struct TranscriptionBenchmarkRunResult: Codable, Sendable {
    var index: Int
    var startedAt: Date
    var finishedAt: Date
    var thermalStateStart: String
    var thermalStateEnd: String
    var batteryLevelStart: Double?
    var batteryLevelEnd: Double?
    var batteryStateStart: String?
    var lowPowerModeEnabled: Bool?

    var audioDuration: TimeInterval
    var processedAudioDuration: TimeInterval
    var modelLoading: TimeInterval
    var audioLoading: TimeInterval
    var transcription: TimeInterval
    var fullPipeline: TimeInterval
    var transcriptionRTF: Double
    var fullPipelineRTF: Double
    var decodingWindowCount: Int
    var decodingFallbackCount: Int
    var decodingFallback: TimeInterval
    var phases: OpenCastTranscriptionPhaseTimings?

    var footprintStartBytes: Int64?
    var footprintEndBytes: Int64?
    /// Peak sampled at 50 ms cadence during the run — a floor, not an exact maximum.
    var footprintPeakSampledBytes: Int64?

    var progressEventCount: Int
    var checkpointEventCount: Int
    var segmentCount: Int
    var textCharacterCount: Int
    var outputTokenCount: Int?
    var textSHA256: String
    var segmentsSHA256: String
}
