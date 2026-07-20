import Foundation
import OpenCastVoiceBoostC

public struct VoiceBoostMetrics: Equatable, Sendable {
    public var estimatedInputLUFS: Double?
    public var estimatedOutputLUFS: Double?
    public var momentaryInputLUFS: Double?
    public var shortTermInputLUFS: Double?
    public var integratedInputLUFS: Double?
    public var currentAutoGainDB: Double
    public var currentCompressorReductionDB: Double
    public var currentLimiterReductionDB: Double
    public var maximumLimiterReductionDB: Double
    public var outputTruePeakDBTP: Double?
    /// Frames of delay the processor's output path carries (the limiter
    /// lookahead). The zero-latency boost-off path is the tap-level
    /// short-circuit, which never invokes the processor.
    public var latencyFrames: Int
    /// Times the belt-and-braces output safety clamp fired since reset.
    /// Structurally zero; any other value is an algorithm defect.
    public var safetyClampCount: Int

    public init(
        estimatedInputLUFS: Double? = nil,
        estimatedOutputLUFS: Double? = nil,
        momentaryInputLUFS: Double? = nil,
        shortTermInputLUFS: Double? = nil,
        integratedInputLUFS: Double? = nil,
        currentAutoGainDB: Double = 0,
        currentCompressorReductionDB: Double = 0,
        currentLimiterReductionDB: Double = 0,
        maximumLimiterReductionDB: Double = 0,
        outputTruePeakDBTP: Double? = nil,
        latencyFrames: Int = 0,
        safetyClampCount: Int = 0
    ) {
        self.estimatedInputLUFS = estimatedInputLUFS
        self.estimatedOutputLUFS = estimatedOutputLUFS
        self.momentaryInputLUFS = momentaryInputLUFS
        self.shortTermInputLUFS = shortTermInputLUFS
        self.integratedInputLUFS = integratedInputLUFS
        self.currentAutoGainDB = currentAutoGainDB
        self.currentCompressorReductionDB = currentCompressorReductionDB
        self.currentLimiterReductionDB = currentLimiterReductionDB
        self.maximumLimiterReductionDB = maximumLimiterReductionDB
        self.outputTruePeakDBTP = outputTruePeakDBTP
        self.latencyFrames = latencyFrames
        self.safetyClampCount = safetyClampCount
    }

    init(cMetrics: OCVBMetrics) {
        estimatedInputLUFS = cMetrics.hasEstimatedInputLUFS == 1
            ? cMetrics.estimatedInputLUFS
            : nil
        estimatedOutputLUFS = cMetrics.hasEstimatedOutputLUFS == 1
            ? cMetrics.estimatedOutputLUFS
            : nil
        momentaryInputLUFS = cMetrics.hasMomentaryInputLUFS == 1
            ? cMetrics.momentaryInputLUFS
            : nil
        shortTermInputLUFS = cMetrics.hasShortTermInputLUFS == 1
            ? cMetrics.shortTermInputLUFS
            : nil
        integratedInputLUFS = cMetrics.hasIntegratedInputLUFS == 1
            ? cMetrics.integratedInputLUFS
            : nil
        currentAutoGainDB = cMetrics.currentAutoGainDB
        currentCompressorReductionDB = cMetrics.currentCompressorReductionDB
        currentLimiterReductionDB = cMetrics.currentLimiterReductionDB
        maximumLimiterReductionDB = cMetrics.maximumLimiterReductionDB
        outputTruePeakDBTP = cMetrics.hasOutputTruePeakDBTP == 1
            ? cMetrics.outputTruePeakDBTP
            : nil
        latencyFrames = Int(cMetrics.latencyFrames)
        safetyClampCount = Int(cMetrics.safetyClampCount)
    }
}
