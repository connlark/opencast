import Foundation

struct BenchmarkMetrics: Codable {
    var durationSeconds: Double
    var sampleRate: Double
    var channelCount: Int
    var blockFrameCount: Int
    var processedFrames: Int
    var blockCount: Int
    var dspProcessingTimeSeconds: Double
    var wallTimeSeconds: Double
    var realtimeFactor: Double
    var averageProcessCallMicroseconds: Double
    var maxProcessCallMicroseconds: Double
    var averageNanosecondsPerFrame: Double
    var peakAbs: Double
    var nanInfSampleCount: Int
    var estimatedInputLUFS: Double?
    var estimatedOutputLUFS: Double?
    var currentAutoGainDB: Double
    var currentCompressorReductionDB: Double
    var currentLimiterReductionDB: Double
    var outputTruePeakDBTP: Double?
}
