import Foundation
import OpenCastVoiceBoostC

public struct VoiceBoostConfiguration: Equatable, Sendable {
    public var isEnabled: Bool
    public var targetLUFS: Double
    public var truePeakCeilingDBTP: Double
    public var maximumPositiveGainDB: Double
    public var maximumNegativeGainDB: Double
    public var usesAdaptiveGain: Bool
    public var usesEqualization: Bool
    public var usesCompression: Bool
    /// Compressor envelope threshold, referenced to the post-auto-gain
    /// signal. The soft knee is centered here: unity below
    /// `threshold - knee/2`, the ratio line above `threshold + knee/2`.
    public var compressorThresholdDB: Double
    public var compressorRatio: Double
    public var compressorKneeWidthDB: Double
    public var compressorAttackSeconds: Double
    public var compressorReleaseSeconds: Double
    public var compressorMaximumReductionDB: Double

    public init(
        isEnabled: Bool = true,
        targetLUFS: Double = -13,
        truePeakCeilingDBTP: Double = -1,
        maximumPositiveGainDB: Double = 13,
        maximumNegativeGainDB: Double = -10,
        usesAdaptiveGain: Bool = true,
        usesEqualization: Bool = true,
        usesCompression: Bool = true,
        compressorThresholdDB: Double = -20,
        compressorRatio: Double = 1.35,
        compressorKneeWidthDB: Double = 6,
        compressorAttackSeconds: Double = 0.010,
        compressorReleaseSeconds: Double = 0.250,
        compressorMaximumReductionDB: Double = 5
    ) {
        self.isEnabled = isEnabled
        self.targetLUFS = targetLUFS
        self.truePeakCeilingDBTP = truePeakCeilingDBTP
        self.maximumPositiveGainDB = maximumPositiveGainDB
        self.maximumNegativeGainDB = maximumNegativeGainDB
        self.usesAdaptiveGain = usesAdaptiveGain
        self.usesEqualization = usesEqualization
        self.usesCompression = usesCompression
        self.compressorThresholdDB = compressorThresholdDB
        self.compressorRatio = compressorRatio
        self.compressorKneeWidthDB = compressorKneeWidthDB
        self.compressorAttackSeconds = compressorAttackSeconds
        self.compressorReleaseSeconds = compressorReleaseSeconds
        self.compressorMaximumReductionDB = compressorMaximumReductionDB
    }

    public static let `default` = VoiceBoostConfiguration()

    var cConfiguration: OCVBConfiguration {
        OCVBConfiguration(
            isEnabled: isEnabled ? 1 : 0,
            targetLUFS: targetLUFS,
            truePeakCeilingDBTP: truePeakCeilingDBTP,
            maximumPositiveGainDB: maximumPositiveGainDB,
            maximumNegativeGainDB: maximumNegativeGainDB,
            usesAdaptiveGain: usesAdaptiveGain ? 1 : 0,
            usesEqualization: usesEqualization ? 1 : 0,
            usesCompression: usesCompression ? 1 : 0,
            compressorThresholdDB: compressorThresholdDB,
            compressorRatio: compressorRatio,
            compressorKneeWidthDB: compressorKneeWidthDB,
            compressorAttackSeconds: compressorAttackSeconds,
            compressorReleaseSeconds: compressorReleaseSeconds,
            compressorMaximumReductionDB: compressorMaximumReductionDB
        )
    }
}
