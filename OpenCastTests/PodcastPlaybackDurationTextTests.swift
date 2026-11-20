import Foundation
import Testing
@testable import OpenCast

@Suite("Podcast playback duration text")
struct PodcastPlaybackDurationTextTests {
    @Test("Parses minute and hour durations")
    func parsesSupportedDurations() {
        #expect(PodcastPlaybackDurationText.parse("1:05") == 65)
        #expect(PodcastPlaybackDurationText.parse("2:03:04") == 7_384)
        #expect(PodcastPlaybackDurationText.parse(" 0:30 ") == 30)
    }

    @Test("Rejects malformed durations")
    func rejectsMalformedDurations() {
        #expect(PodcastPlaybackDurationText.parse("65") == nil)
        #expect(PodcastPlaybackDurationText.parse("1:60") == nil)
        #expect(PodcastPlaybackDurationText.parse("1::05") == nil)
        #expect(PodcastPlaybackDurationText.parse("-1:05") == nil)
        #expect(PodcastPlaybackDurationText.parse("١:٠٥") == nil)
        #expect(PodcastPlaybackDurationText.parse("1:02:03:04") == nil)
    }

    @Test("Large finite durations format without integer conversion")
    func largeFiniteDurationsFormatSafely() {
        let formatted = PodcastPlaybackDurationText.format(TimeInterval(Int.max) * 2)

        #expect(!formatted.isEmpty)
        #expect(formatted.unicodeScalars.allSatisfy { $0.isASCII })
        #expect(PodcastPlaybackDurationText.parse(formatted) != nil)
    }
}
