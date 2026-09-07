import Foundation
import Testing
@testable import OpenCast

@Suite("Show notes timestamp link")
struct ShowNotesTimestampLinkTests {
    @Test("Seconds round-trip through the link URL")
    func roundTrip() throws {
        let url = try #require(ShowNotesTimestampLink.url(seconds: 3753))
        #expect(url.absoluteString == "opencast-shownotes://seek?t=3753")
        #expect(ShowNotesTimestampLink.seconds(from: url) == 3753)

        let start = try #require(ShowNotesTimestampLink.url(seconds: 0))
        #expect(ShowNotesTimestampLink.seconds(from: start) == 0)
    }

    @Test("Foreign and malformed URLs decode to nil")
    func rejectsForeignURLs() throws {
        let rejected = [
            "https://example.com/?t=5",
            "tel:5551234567",
            "opencast-shownotes://seek",
            "opencast-shownotes://seek?t=abc",
            "opencast-shownotes://seek?t=-5",
            "opencast-shownotes://other?t=5",
        ]
        for string in rejected {
            let url = try #require(URL(string: string))
            #expect(ShowNotesTimestampLink.seconds(from: url) == nil, "\(string)")
        }
    }
}
