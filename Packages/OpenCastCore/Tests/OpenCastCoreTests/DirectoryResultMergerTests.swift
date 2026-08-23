import Foundation
import OpenCastCore
import Testing

@Suite("Directory result merger")
struct DirectoryResultMergerTests {
    @Test("Serial-shaped results merge into one by Apple ID with PI fill-in")
    func serialShapedResultsMergeIntoOne() throws {
        let apple = DirectoryPodcastResult(
            id: 917_918_570,
            title: "Serial",
            artistName: "Serial Productions",
            feedURL: URL(string: "https://feeds.example.com/windowed"),
            artworkURL: URL(string: "https://images.example.com/serial-apple.jpg")
        )
        let podcastIndex = DirectoryPodcastResult(
            id: "podcastindex:745392",
            title: "Serial (PI title)",
            artistName: "PI Author",
            feedURL: URL(string: "https://feeds.example.com/full"),
            collectionViewURL: URL(string: "https://serial.example.com"),
            appleID: 917_918_570,
            podcastIndexID: 745_392,
            podcastGUID: "2d7400e3-bacb-52fd-aabc-0da55e39f98b",
            sources: [.podcastIndex],
            feedCandidates: [
                DirectoryFeedCandidate(
                    source: .podcastIndex,
                    feedURL: URL(string: "https://feeds.example.com/full")!,
                    reportedEpisodeCount: 124
                )
            ]
        )

        let merged = DirectoryResultMerger.merge(
            appleResults: [apple],
            podcastIndexResults: [podcastIndex]
        )

        #expect(merged.count == 1)
        let result = try #require(merged.first)
        #expect(result.id == "apple:917918570")
        #expect(result.title == "Serial")
        #expect(result.artistName == "Serial Productions")
        #expect(result.feedURL?.absoluteString == "https://feeds.example.com/windowed")
        #expect(result.artworkURL?.absoluteString == "https://images.example.com/serial-apple.jpg")
        #expect(result.collectionViewURL?.absoluteString == "https://serial.example.com")
        #expect(result.appleID == 917_918_570)
        #expect(result.podcastIndexID == 745_392)
        #expect(result.podcastGUID == "2d7400e3-bacb-52fd-aabc-0da55e39f98b")
        #expect(result.sources == [.apple, .podcastIndex])
        #expect(result.feedCandidates.map(\.feedURL.absoluteString) == [
            "https://feeds.example.com/windowed",
            "https://feeds.example.com/full",
        ])
    }

    @Test("Apple order is preserved and unmatched PI results append in order")
    func appleOrderPreservedAndUnmatchedAppend() {
        let appleResults = [
            DirectoryPodcastResult(id: 1, title: "Apple One", feedURL: URL(string: "https://example.com/a1.xml")),
            DirectoryPodcastResult(id: 2, title: "Apple Two", feedURL: URL(string: "https://example.com/a2.xml")),
            DirectoryPodcastResult(id: 3, title: "Apple Three", feedURL: URL(string: "https://example.com/a3.xml")),
        ]
        let podcastIndexResults = [
            makePodcastIndexResult(id: 90, feedURL: "https://example.com/pi-only-1.xml"),
            makePodcastIndexResult(id: 91, appleID: 2, feedURL: "https://example.com/a2-alt.xml"),
            makePodcastIndexResult(id: 92, feedURL: "https://example.com/pi-only-2.xml"),
        ]

        let merged = DirectoryResultMerger.merge(
            appleResults: appleResults,
            podcastIndexResults: podcastIndexResults
        )

        #expect(merged.map(\.title) == [
            "Apple One", "Apple Two", "Apple Three", "PI 90", "PI 92",
        ])
        #expect(merged[1].podcastIndexID == 91)
        #expect(merged[1].sources == [.apple, .podcastIndex])
    }

    @Test("Canonical feed URL matches when IDs are absent")
    func canonicalFeedURLMatchesWhenIDsAbsent() {
        let apple = DirectoryPodcastResult(
            id: 5,
            title: "URL Matched",
            feedURL: URL(string: "https://Example.com/feed/")
        )
        let podcastIndex = makePodcastIndexResult(id: 50, feedURL: "https://example.com/feed")

        let merged = DirectoryResultMerger.merge(
            appleResults: [apple],
            podcastIndexResults: [podcastIndex]
        )

        #expect(merged.count == 1)
        #expect(merged.first?.podcastIndexID == 50)
        #expect(merged.first?.feedCandidates.count == 1)
    }

    @Test("Podcast GUID matches when Apple IDs are absent")
    func podcastGUIDMatchesWhenAppleIDsAbsent() {
        let apple = DirectoryPodcastResult(
            id: "apple:9",
            title: "GUID Matched",
            feedURL: URL(string: "https://example.com/a.xml"),
            podcastGUID: "ABC-123",
            sources: [.apple],
            feedCandidates: [
                DirectoryFeedCandidate(source: .apple, feedURL: URL(string: "https://example.com/a.xml")!)
            ]
        )
        let podcastIndex = makePodcastIndexResult(
            id: 90,
            guid: "abc-123",
            feedURL: "https://example.com/b.xml"
        )

        let merged = DirectoryResultMerger.merge(
            appleResults: [apple],
            podcastIndexResults: [podcastIndex]
        )

        #expect(merged.count == 1)
        #expect(merged.first?.podcastIndexID == 90)
        #expect(merged.first?.feedCandidates.count == 2)
    }

    @Test("Titles never merge results")
    func titlesNeverMergeResults() {
        let apple = DirectoryPodcastResult(id: 7, title: "Same Title", feedURL: URL(string: "https://example.com/apple.xml"))
        let podcastIndex = makePodcastIndexResult(id: 70, title: "Same Title", feedURL: "https://example.com/other.xml")

        let merged = DirectoryResultMerger.merge(
            appleResults: [apple],
            podcastIndexResults: [podcastIndex]
        )

        #expect(merged.count == 2)
    }

    @Test("Apple ID matching wins over feed URL matching")
    func appleIDWinsOverFeedURL() {
        let apple = DirectoryPodcastResult(id: 8, title: "Apple", feedURL: URL(string: "https://example.com/shared.xml"))
        let byURL = makePodcastIndexResult(id: 80, feedURL: "https://example.com/shared.xml")
        let byAppleID = makePodcastIndexResult(id: 81, appleID: 8, feedURL: "https://example.com/other.xml")

        let merged = DirectoryResultMerger.merge(
            appleResults: [apple],
            podcastIndexResults: [byURL, byAppleID]
        )

        #expect(merged.first?.podcastIndexID == 81)
        #expect(merged.count == 2)
    }

    @Test("Duplicate candidates collapse and backfill hints")
    func duplicateCandidatesCollapseAndBackfillHints() throws {
        let url = URL(string: "https://example.com/feed.xml")!
        let candidates = DirectoryResultMerger.mergedCandidates([
            DirectoryFeedCandidate(source: .apple, feedURL: url),
            DirectoryFeedCandidate(
                source: .podcastIndex,
                feedURL: URL(string: "https://EXAMPLE.com/feed.xml")!,
                reportedEpisodeCount: 42
            ),
        ])

        #expect(candidates.count == 1)
        let candidate = try #require(candidates.first)
        #expect(candidate.source == .apple)
        #expect(candidate.reportedEpisodeCount == 42)
    }

    private func makePodcastIndexResult(
        id: Int,
        appleID: Int? = nil,
        title: String? = nil,
        guid: String? = nil,
        feedURL: String
    ) -> DirectoryPodcastResult {
        let url = URL(string: feedURL)!
        return DirectoryPodcastResult(
            id: "podcastindex:\(id)",
            title: title ?? "PI \(id)",
            feedURL: url,
            appleID: appleID,
            podcastIndexID: id,
            podcastGUID: guid,
            sources: [.podcastIndex],
            feedCandidates: [DirectoryFeedCandidate(source: .podcastIndex, feedURL: url)]
        )
    }
}
