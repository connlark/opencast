import Testing
@testable import OpenCastPlayback

@Suite("Playback episode boundaries")
struct PlaybackEpisodeBoundariesTests {
    @Test("Ordinary starts honor the intro while exact positions stay caller-owned")
    func ordinaryStartPositions() {
        let boundaries = PlaybackEpisodeBoundaries(
            skipIntroSeconds: 30,
            skipOutroSeconds: 15
        )

        #expect(PlaybackEpisodeBoundaries.disabled.ordinaryStartPosition(8, duration: 120) == 8)
        #expect(boundaries.ordinaryStartPosition(0, duration: 120) == 30)
        #expect(boundaries.ordinaryStartPosition(10, duration: 120) == 30)
        #expect(boundaries.ordinaryStartPosition(45, duration: 120) == 45)
        #expect(boundaries.ordinaryStartPosition(5, duration: nil) == 30)
        #expect(boundaries.outroCutoff(duration: nil) == nil)
    }

    @Test("Outro crossing is strict and requires a valid playable span")
    func outroCrossing() {
        let boundaries = PlaybackEpisodeBoundaries(
            skipIntroSeconds: 15,
            skipOutroSeconds: 10
        )

        #expect(!boundaries.crossesOutro(from: 89, to: 89.99, duration: 100))
        #expect(boundaries.crossesOutro(from: 89, to: 90, duration: 100))
        #expect(!boundaries.crossesOutro(from: 90, to: 95, duration: 100))
        #expect(!boundaries.crossesOutro(from: 89, to: 90, duration: nil))
        #expect(!boundaries.crossesOutro(from: 0, to: 20, duration: 20))
    }

    @Test("Invalid trims sanitize to disabled boundaries")
    func invalidTrimsAreDisabled() {
        let boundaries = PlaybackEpisodeBoundaries(
            skipIntroSeconds: .infinity,
            skipOutroSeconds: -.infinity
        )

        #expect(boundaries == .disabled)
    }
}
