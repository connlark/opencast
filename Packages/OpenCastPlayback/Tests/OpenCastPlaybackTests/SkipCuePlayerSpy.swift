import Foundation
@testable import OpenCastPlayback

@MainActor
final class SkipCuePlayerSpy: PlaybackSkipCuePlaying {
    private let playResult: Bool
    private(set) var isSounding = false
    private(set) var playCount = 0
    private(set) var stopCount = 0
    var onFinish: (@MainActor () -> Void)?
    /// Runs inside `stop()`, so a test can read the controller at that moment.
    var onStop: (() -> Void)?

    init(playResult: Bool) {
        self.playResult = playResult
    }

    func play() -> Bool {
        playCount += 1
        isSounding = playResult
        return playResult
    }

    func stop() {
        stopCount += 1
        isSounding = false
        onStop?()
    }

    func finish() {
        isSounding = false
        onFinish?()
    }
}
