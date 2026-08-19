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

    @Test("Formats durations for direct editing")
    func formatsDurations() {
        #expect(PodcastPlaybackDurationText.format(0) == "0:00")
        #expect(PodcastPlaybackDurationText.format(65) == "1:05")
        #expect(PodcastPlaybackDurationText.format(7_384) == "2:03:04")
        #expect(PodcastPlaybackDurationText.format(65).unicodeScalars.allSatisfy { $0.isASCII })
    }

    @Test("Shared duration formatting honors explicit locales")
    func sharedFormattingUsesLocale() {
        #expect((65 as TimeInterval).formattedPlaybackDuration(locale: Locale(identifier: "en_US_POSIX")) == "1:05")
        let arabic = (65 as TimeInterval).formattedPlaybackDuration(
            locale: Locale(identifier: "ar_SA")
        )
        #expect(arabic != "1:05")
        #expect(arabic.unicodeScalars.contains { !$0.isASCII })
    }

    @Test("Large finite durations format without integer conversion")
    func largeFiniteDurationsFormatSafely() {
        let formatted = PodcastPlaybackDurationText.format(TimeInterval(Int.max) * 2)

        #expect(!formatted.isEmpty)
        #expect(formatted.unicodeScalars.allSatisfy { $0.isASCII })
        #expect(PodcastPlaybackDurationText.parse(formatted) != nil)
    }
}
