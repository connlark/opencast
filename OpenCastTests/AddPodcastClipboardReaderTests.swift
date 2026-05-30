import Testing
@testable import OpenCast

@Suite("Add podcast clipboard reader")
struct AddPodcastClipboardReaderTests {
    @Test("Extracts HTTP and HTTPS URLs")
    func extractsHTTPAndHTTPSURLs() {
        #expect(AddPodcastClipboardReader.feedURLString(from: " http://example.com/feed.xml\n") == "http://example.com/feed.xml")
        #expect(AddPodcastClipboardReader.feedURLString(from: "https://example.com/podcast/rss") == "https://example.com/podcast/rss")
    }

    @Test("Rejects non-web or incomplete clipboard contents")
    func rejectsNonWebOrIncompleteClipboardContents() {
        #expect(AddPodcastClipboardReader.feedURLString(from: nil) == nil)
        #expect(AddPodcastClipboardReader.feedURLString(from: "") == nil)
        #expect(AddPodcastClipboardReader.feedURLString(from: "not a url") == nil)
        #expect(AddPodcastClipboardReader.feedURLString(from: "ftp://example.com/feed.xml") == nil)
        #expect(AddPodcastClipboardReader.feedURLString(from: "https:///feed.xml") == nil)
    }
}
