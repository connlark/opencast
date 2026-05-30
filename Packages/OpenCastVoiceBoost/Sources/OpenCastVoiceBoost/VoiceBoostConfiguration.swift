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

    public init(
        isEnabled: Bool = true,
        targetLUFS: Double = -13,
        truePeakCeilingDBTP: Double = -1,
        maximumPositiveGainDB: Double = 13,
        maximumNegativeGainDB: Double = -10,
        usesAdaptiveGain: Bool = true,
        usesEqualization: Bool = true,
        usesCompression: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.targetLUFS = targetLUFS
        self.truePeakCeilingDBTP = truePeakCeilingDBTP
        self.maximumPositiveGainDB = maximumPositiveGainDB
        self.maximumNegativeGainDB = maximumNegativeGainDB
        self.usesAdaptiveGain = usesAdaptiveGain
        self.usesEqualization = usesEqualization
        self.usesCompression = usesCompression
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
            usesCompression: usesCompression ? 1 : 0
        )
    }
}
