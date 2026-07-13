import Foundation
@preconcurrency import WhisperKit

/// WhisperKit per-phase totals and run counts exported for benchmark and
/// proof results. Not part of the persisted transcript document schema.
public struct OpenCastTranscriptionPhaseTimings: Codable, Sendable, Equatable {
    public var inputAudioSeconds: TimeInterval
    public var timeToFirstToken: TimeInterval?
    public var modelLoading: TimeInterval
    public var prewarmLoadTime: TimeInterval
    public var encoderLoadTime: TimeInterval
    public var decoderLoadTime: TimeInterval
    public var encoderSpecializationTime: TimeInterval?
    public var decoderSpecializationTime: TimeInterval?
    public var tokenizerLoadTime: TimeInterval
    public var audioLoading: TimeInterval
    public var audioProcessing: TimeInterval
    public var logmels: TimeInterval
    public var encoding: TimeInterval
    public var decodingInit: TimeInterval
    public var decodingLoop: TimeInterval
    public var decodingPredictions: TimeInterval
    public var decodingFiltering: TimeInterval
    public var decodingSampling: TimeInterval
    public var decodingFallback: TimeInterval
    public var decodingWindowing: TimeInterval
    public var decodingKvCaching: TimeInterval
    public var decodingWordTimestamps: TimeInterval
    public var decodingNonPrediction: TimeInterval
    public var fullPipeline: TimeInterval
    public var audioProcessingRunCount: Int
    public var logmelRunCount: Int
    public var encodingRunCount: Int
    public var decodingLoopCount: Int
    public var kvUpdateRunCount: Int
    public var timestampAlignmentRunCount: Int
    public var fallbackCount: Int
    public var windowCount: Int
    public var outputTokenCount: Int

    init(timings: TranscriptionTimings, outputTokenCount: Int) {
        inputAudioSeconds = timings.inputAudioSeconds
        if timings.pipelineStart < .greatestFiniteMagnitude,
           timings.firstTokenTime < .greatestFiniteMagnitude,
           timings.firstTokenTime >= timings.pipelineStart {
            timeToFirstToken = timings.firstTokenTime - timings.pipelineStart
        } else {
            timeToFirstToken = nil
        }
        modelLoading = timings.modelLoading
        prewarmLoadTime = timings.prewarmLoadTime
        encoderLoadTime = timings.encoderLoadTime
        decoderLoadTime = timings.decoderLoadTime
        encoderSpecializationTime = timings.encoderSpecializationTime
        decoderSpecializationTime = timings.decoderSpecializationTime
        tokenizerLoadTime = timings.tokenizerLoadTime
        audioLoading = timings.audioLoading
        audioProcessing = timings.audioProcessing
        logmels = timings.logmels
        encoding = timings.encoding
        decodingInit = timings.decodingInit
        decodingLoop = timings.decodingLoop
        decodingPredictions = timings.decodingPredictions
        decodingFiltering = timings.decodingFiltering
        decodingSampling = timings.decodingSampling
        decodingFallback = timings.decodingFallback
        decodingWindowing = timings.decodingWindowing
        decodingKvCaching = timings.decodingKvCaching
        decodingWordTimestamps = timings.decodingWordTimestamps
        decodingNonPrediction = timings.decodingNonPrediction
        fullPipeline = timings.fullPipeline
        audioProcessingRunCount = Int(timings.totalAudioProcessingRuns)
        logmelRunCount = Int(timings.totalLogmelRuns)
        encodingRunCount = Int(timings.totalEncodingRuns)
        decodingLoopCount = Int(timings.totalDecodingLoops)
        kvUpdateRunCount = Int(timings.totalKVUpdateRuns)
        timestampAlignmentRunCount = Int(timings.totalTimestampAlignmentRuns)
        fallbackCount = Int(timings.totalDecodingFallbacks)
        windowCount = Int(timings.totalDecodingWindows)
        self.outputTokenCount = outputTokenCount
    }
}
