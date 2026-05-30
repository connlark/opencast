#if DEBUG
import Foundation

struct VoiceBoostDeviceProbeAudioSessionReport: Encodable {
    let stage: String
    let applicationState: String
    let category: String
    let mode: String
    let routeOutputs: [String]
    let isOtherAudioPlaying: Bool
    let secondaryAudioShouldBeSilencedHint: Bool
    let succeeded: Bool
    let errorDomain: String?
    let errorCode: Int?
    let errorDescription: String?
}
#endif
