import Foundation
import OpenCastPlayback

protocol PlaybackVoiceBoostControlling: AnyObject {
    func setVoiceBoostEnabled(_ isEnabled: Bool)
}

protocol PlaybackSettingsControlling: PlaybackVoiceBoostControlling {
    var rate: Float { get }

    func setRate(_ rate: Float)
    func setSkipIntervals(backward: TimeInterval, forward: TimeInterval)
    func setAutoSkipEnabled(_ isEnabled: Bool)
}

extension AVFoundationPlaybackController: PlaybackSettingsControlling {}
