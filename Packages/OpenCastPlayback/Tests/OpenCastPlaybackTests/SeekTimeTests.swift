import CoreMedia
import Testing
@testable import OpenCastPlayback

@Suite("Seek time")
struct SeekTimeTests {
    @Test("An exact landing never rounds below the target")
    func exactLandingRoundsUp() {
        let exact = AVFoundationPlaybackController.seekTime(for: 60.002, landsExactly: true)
        #expect(exact.timescale == 600)
        #expect(exact.seconds >= 60.002)
        #expect(exact.seconds - 60.002 < 1.0 / 600)
        #expect(AVFoundationPlaybackController.seekTime(for: 60, landsExactly: true).seconds == 60)
    }

    @Test("A tolerant seek keeps the nearest tick")
    func tolerantSeekRoundsToNearest() {
        let tolerant = AVFoundationPlaybackController.seekTime(for: 60.002, landsExactly: false)
        #expect(tolerant == CMTime(seconds: 60.002, preferredTimescale: 600))
        #expect(tolerant.seconds < 60.002)
    }
}
