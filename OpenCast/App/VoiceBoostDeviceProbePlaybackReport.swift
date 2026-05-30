#if DEBUG
import Foundation
import OpenCastPlayback

struct VoiceBoostDeviceProbePlaybackReport: Encodable {
    let state: String
    let failureMessage: String?
    let position: TimeInterval
    let duration: TimeInterval?
    let rate: Float
    let hasEpisode: Bool
    let episodeTitle: String?
    let episodeAudioURL: String?

    init(snapshot: PlaybackSnapshot) {
        state = snapshot.state.accessibilityDescription
        if case .failed(let message) = snapshot.state {
            failureMessage = message
        } else {
            failureMessage = nil
        }
        position = snapshot.position
        duration = snapshot.duration
        rate = snapshot.rate
        hasEpisode = snapshot.currentEpisode != nil
        episodeTitle = snapshot.currentEpisode?.title
        episodeAudioURL = snapshot.currentEpisode?.audioURL?.absoluteString
    }
}
#endif
