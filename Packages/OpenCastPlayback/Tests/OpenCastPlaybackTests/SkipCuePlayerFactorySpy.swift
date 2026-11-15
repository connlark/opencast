import Foundation
@testable import OpenCastPlayback

@MainActor
final class SkipCuePlayerFactorySpy {
    struct Failure: Error {}

    var failure: (any Error)?
    var playResult = true
    private(set) var requestedURLs: [URL] = []
    private(set) var cues: [SkipCuePlayerSpy] = []

    var latestCue: SkipCuePlayerSpy? {
        cues.last
    }

    func make(_ url: URL) throws -> any PlaybackSkipCuePlaying {
        requestedURLs.append(url)
        if let failure {
            throw failure
        }
        let cue = SkipCuePlayerSpy(playResult: playResult)
        cues.append(cue)
        return cue
    }
}
