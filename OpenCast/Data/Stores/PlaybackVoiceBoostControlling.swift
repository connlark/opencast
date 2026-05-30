import Foundation
import OpenCastPlayback

protocol PlaybackVoiceBoostControlling: AnyObject {
    func setVoiceBoostEnabled(_ isEnabled: Bool)
}

protocol PlaybackSettingsControlling: PlaybackVoiceBoostControlling {
    func setSkipIntervals(backward: TimeInterval, forward: TimeInterval)
}

extension AVFoundationPlaybackController: PlaybackSettingsControlling {}
