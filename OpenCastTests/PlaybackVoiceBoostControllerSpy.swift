import Foundation
@testable import OpenCast

@MainActor
final class PlaybackVoiceBoostControllerSpy: PlaybackSettingsControlling {
    private(set) var appliedValues: [Bool] = []
    private(set) var appliedSkipIntervals: [(backward: TimeInterval, forward: TimeInterval)] = []
    private(set) var appliedAutoSkipValues: [Bool] = []

    func setVoiceBoostEnabled(_ isEnabled: Bool) {
        appliedValues.append(isEnabled)
    }

    func setSkipIntervals(backward: TimeInterval, forward: TimeInterval) {
        appliedSkipIntervals.append((backward, forward))
    }

    func setAutoSkipEnabled(_ isEnabled: Bool) {
        appliedAutoSkipValues.append(isEnabled)
    }
}
