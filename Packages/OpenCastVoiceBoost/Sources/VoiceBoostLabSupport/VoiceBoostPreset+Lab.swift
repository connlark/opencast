import Foundation
import OpenCastVoiceBoost

extension VoiceBoostPreset {
    init(labName: String) throws {
        switch labName {
        case "limiterOnly", "limiter-only", "limiter":
            self = .limiterOnly
        case "transparent":
            self = .transparent
        case "default":
            self = .default
        case "clarity":
            self = .clarity
        case "loud":
            self = .loud
        default:
            throw LabError.unknownPreset(labName)
        }
    }
}
