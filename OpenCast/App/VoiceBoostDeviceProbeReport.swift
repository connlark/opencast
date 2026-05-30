#if DEBUG
import Foundation

struct VoiceBoostDeviceProbeReport: Encodable {
    let schemaVersion: Int
    let trigger: String
    let startedAt: Date
    let finishedAt: Date
    let startedApplicationState: String
    let finishedApplicationState: String
    let feedURL: String
    let result: String
    let errorMessage: String?
    let episodeTitle: String?
    let episodeAudioURL: String?
    let processedFramesAdvanced: Bool
    let timedProcessCallbacksAdvanced: Bool
    let audioSessionPreflight: VoiceBoostDeviceProbeAudioSessionReport?
    let audioSessionFinal: VoiceBoostDeviceProbeAudioSessionReport?
    let initialDiagnostics: VoiceBoostDeviceProbeDiagnosticsReport?
    let finalDiagnostics: VoiceBoostDeviceProbeDiagnosticsReport?
    let initialPlayback: VoiceBoostDeviceProbePlaybackReport
    let finalPlayback: VoiceBoostDeviceProbePlaybackReport
}
#endif
