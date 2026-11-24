import Foundation
import Testing
@testable import OpenCast

@Suite("Podcast feed URL detector")
struct PodcastFeedURLDetectorTests {
    @Test(
        "Opens a feed address, assuming https when it has no scheme",
        arguments: [
            (" http://example.com/feed.xml\n", "http://example.com/feed.xml"),
            ("https://example.com/podcast/rss", "https://example.com/podcast/rss"),
            ("example.com/feed.xml", "https://example.com/feed.xml"),
            ("//feeds.example.com/feed.xml", "https://feeds.example.com/feed.xml"),
            ("feeds.example.com:8443/private.xml?token=secret", "https://feeds.example.com:8443/private.xml?token=secret"),
            ("user:secret@feeds.example.com:8443/private.xml", "https://user:secret@feeds.example.com:8443/private.xml"),
        ]
    )
    func opensFeedAddresses(text: String, address: String) {
        #expect(PodcastFeedURLDetector.openableFeedURL(from: text)?.absoluteString == address)
    }

    @Test(
        "Opens an address whose host is an IP address or a name with a port",
        arguments: [
            ("192.0.2.10/feed.xml", "192.0.2.10", nil),
            ("localhost:8080/feed.xml", "localhost", 8080),
        ] as [(String, String, Int?)]
    )
    func opensAddressesOnOtherHosts(text: String, host: String, port: Int?) throws {
        let url = try #require(PodcastFeedURLDetector.openableFeedURL(from: text))
        #expect(url.scheme == "https")
        #expect(url.host() == host)
        #expect(url.port == port)
    }

    @Test(
        "Text that is not a feed address opens nothing",
        arguments: [
            "",
            "podcast search",
            "ftp://example.com/feed.xml",
            "https:///feed.xml",
            "example.com",
            "24/7 news",
            "AC/DC",
            "v1.2/beta",
            "9:30/8:30",
        ]
    )
    func opensNothingForOtherText(text: String) {
        #expect(PodcastFeedURLDetector.openableFeedURL(from: text) == nil)
    }
}
