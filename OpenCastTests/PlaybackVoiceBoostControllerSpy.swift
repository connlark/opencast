import Foundation
@testable import OpenCast

@MainActor
final class PlaybackVoiceBoostControllerSpy: @MainActor PlaybackSettingsControlling {
    /// The Auto-Skip switch and the skip cue in the order they reached the
    /// controller.
    enum AutoSkipCall: Equatable {
        case enabled(Bool)
        case cue(URL?)
    }

    private(set) var rate: Float = 1
    private(set) var appliedRates: [Float] = []
    private(set) var appliedValues: [Bool] = []
    private(set) var appliedSkipIntervals: [(backward: TimeInterval, forward: TimeInterval)] = []
    private(set) var appliedAutoSkipValues: [Bool] = []
    private(set) var autoSkipCalls: [AutoSkipCall] = []
    private(set) var previewedAutoSkipCues: [URL] = []

    var appliedAutoSkipCues: [URL?] {
        autoSkipCalls.compactMap { call -> URL?? in
            guard case .cue(let url) = call else {
                return nil
            }
            return .some(url)
        }
    }

    func setRate(_ rate: Float) {
        self.rate = rate
        appliedRates.append(rate)
    }

    func setVoiceBoostEnabled(_ isEnabled: Bool) {
        appliedValues.append(isEnabled)
    }

    func setSkipIntervals(backward: TimeInterval, forward: TimeInterval) {
        appliedSkipIntervals.append((backward, forward))
    }

    func setAutoSkipEnabled(_ isEnabled: Bool) {
        appliedAutoSkipValues.append(isEnabled)
        autoSkipCalls.append(.enabled(isEnabled))
    }

    func setAutoSkipCue(_ url: URL?) {
        autoSkipCalls.append(.cue(url))
    }

    func previewAutoSkipCue(_ url: URL) {
        previewedAutoSkipCues.append(url)
    }
}
