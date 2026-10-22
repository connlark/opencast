import Testing
@testable import OpenCastPlayback

@Suite("PlaybackSeekIntent")
struct PlaybackSeekIntentTests {
    @Test("Chapter jumps and restores land exactly; the rest tolerate")
    func landsExactly() {
        #expect(PlaybackSeekIntent.chapter.landsExactly)
        #expect(PlaybackSeekIntent.restore.landsExactly)
        #expect(!PlaybackSeekIntent.scrub.landsExactly)
        #expect(!PlaybackSeekIntent.skipButton.landsExactly)
        #expect(!PlaybackSeekIntent.autoSkip.landsExactly)
    }
}
