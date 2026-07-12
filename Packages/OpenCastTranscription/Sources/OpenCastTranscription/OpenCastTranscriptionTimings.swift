import Foundation

public struct OpenCastTranscriptionTimings: Codable, Sendable, Equatable {
    public var audioDuration: TimeInterval
    /// Audio actually decoded in this run: full duration minus any resume offset.
    public var processedAudioDuration: TimeInterval
    public var modelLoading: TimeInterval
    public var audioLoading: TimeInterval
    public var transcription: TimeInterval
    public var fullPipeline: TimeInterval
    public var realTimeFactor: Double
    public var decodingFallbackCount: Int
    public var decodingFallback: TimeInterval
    public var decodingWindowCount: Int
    public var phases: OpenCastTranscriptionPhaseTimings?

    public var transcriptionRTF: Double {
        processedAudioDuration > 0 ? transcription / processedAudioDuration : 0
    }

    public var fullPipelineRTF: Double {
        processedAudioDuration > 0 ? fullPipeline / processedAudioDuration : 0
    }

    public init(
        audioDuration: TimeInterval,
        processedAudioDuration: TimeInterval? = nil,
        modelLoading: TimeInterval,
        audioLoading: TimeInterval,
        transcription: TimeInterval,
        fullPipeline: TimeInterval,
        realTimeFactor: Double,
        decodingFallbackCount: Int = 0,
        decodingFallback: TimeInterval = 0,
        decodingWindowCount: Int = 0,
        phases: OpenCastTranscriptionPhaseTimings? = nil
    ) {
        self.audioDuration = audioDuration
        self.processedAudioDuration = processedAudioDuration ?? audioDuration
        self.modelLoading = modelLoading
        self.audioLoading = audioLoading
        self.transcription = transcription
        self.fullPipeline = fullPipeline
        self.realTimeFactor = realTimeFactor
        self.decodingFallbackCount = decodingFallbackCount
        self.decodingFallback = decodingFallback
        self.decodingWindowCount = decodingWindowCount
        self.phases = phases
    }
}
