import Testing
@testable import OpenCast

@Suite("Podcast feed URL detector")
struct PodcastFeedURLDetectorTests {
    @Test("Accepts trimmed HTTP and HTTPS URLs with hosts")
    func acceptsWebURLsWithHosts() {
        #expect(
            PodcastFeedURLDetector.feedURLString(from: " http://example.com/feed.xml\n")
                == "http://example.com/feed.xml"
        )
        #expect(
            PodcastFeedURLDetector.feedURLString(from: "https://example.com/podcast/rss")
                == "https://example.com/podcast/rss"
        )
    }

    @Test("Rejects non-feed URL shapes")
    func rejectsNonFeedURLShapes() {
        #expect(PodcastFeedURLDetector.feedURLString(from: nil) == nil)
        #expect(PodcastFeedURLDetector.feedURLString(from: "") == nil)
        #expect(PodcastFeedURLDetector.feedURLString(from: "podcast search") == nil)
        #expect(PodcastFeedURLDetector.feedURLString(from: "ftp://example.com/feed.xml") == nil)
        #expect(PodcastFeedURLDetector.feedURLString(from: "example.com/feed.xml") == nil)
        #expect(PodcastFeedURLDetector.feedURLString(from: "https:///feed.xml") == nil)
    }
}
