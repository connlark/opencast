import Foundation
import OpenCastVoiceBoostC

public struct VoiceBoostMetrics: Equatable, Sendable {
    public var estimatedInputLUFS: Double?
    public var estimatedOutputLUFS: Double?
    public var currentAutoGainDB: Double
    public var currentCompressorReductionDB: Double
    public var currentLimiterReductionDB: Double
    public var outputTruePeakDBTP: Double?

    public init(
        estimatedInputLUFS: Double? = nil,
        estimatedOutputLUFS: Double? = nil,
        currentAutoGainDB: Double = 0,
        currentCompressorReductionDB: Double = 0,
        currentLimiterReductionDB: Double = 0,
        outputTruePeakDBTP: Double? = nil
    ) {
        self.estimatedInputLUFS = estimatedInputLUFS
        self.estimatedOutputLUFS = estimatedOutputLUFS
        self.currentAutoGainDB = currentAutoGainDB
        self.currentCompressorReductionDB = currentCompressorReductionDB
        self.currentLimiterReductionDB = currentLimiterReductionDB
        self.outputTruePeakDBTP = outputTruePeakDBTP
    }

    init(cMetrics: OCVBMetrics) {
        estimatedInputLUFS = cMetrics.hasEstimatedInputLUFS == 1
            ? cMetrics.estimatedInputLUFS
            : nil
        estimatedOutputLUFS = cMetrics.hasEstimatedOutputLUFS == 1
            ? cMetrics.estimatedOutputLUFS
            : nil
        currentAutoGainDB = cMetrics.currentAutoGainDB
        currentCompressorReductionDB = cMetrics.currentCompressorReductionDB
        currentLimiterReductionDB = cMetrics.currentLimiterReductionDB
        outputTruePeakDBTP = cMetrics.hasOutputTruePeakDBTP == 1
            ? cMetrics.outputTruePeakDBTP
            : nil
    }
}
