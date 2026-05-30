import Foundation

public enum VoiceBoostPreset: Sendable {
    case limiterOnly
    case transparent
    case `default`
    case clarity
    case loud

    public var configuration: VoiceBoostConfiguration {
        switch self {
        case .limiterOnly:
            VoiceBoostConfiguration(
                isEnabled: true,
                targetLUFS: -14,
                truePeakCeilingDBTP: -1,
                maximumPositiveGainDB: 0,
                maximumNegativeGainDB: 0,
                usesAdaptiveGain: false,
                usesEqualization: false,
                usesCompression: false
            )
        case .transparent:
            VoiceBoostConfiguration(
                isEnabled: true,
                targetLUFS: -15,
                truePeakCeilingDBTP: -1,
                maximumPositiveGainDB: 9,
                maximumNegativeGainDB: -8,
                usesAdaptiveGain: true,
                usesEqualization: false,
                usesCompression: false
            )
        case .default:
            .default
        case .clarity:
            VoiceBoostConfiguration(
                isEnabled: true,
                targetLUFS: -14,
                truePeakCeilingDBTP: -1,
                maximumPositiveGainDB: 12,
                maximumNegativeGainDB: -10
            )
        case .loud:
            VoiceBoostConfiguration(
                isEnabled: true,
                targetLUFS: -12,
                truePeakCeilingDBTP: -1.5,
                maximumPositiveGainDB: 15,
                maximumNegativeGainDB: -12
            )
        }
    }
}
