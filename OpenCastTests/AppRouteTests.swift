import Testing
@testable import OpenCast

@MainActor
@Suite("App routes")
struct AppRouteTests {
    @Test("A show is the same screen whichever list settings it opened under")
    func podcastDetailIgnoresTheEpisodeListOverride() {
        let plain = AppRoute.podcastDetail(feedURL: "https://example.com/feed.xml")
        let fromInbox = AppRoute.podcastDetail(
            feedURL: "https://example.com/feed.xml",
            episodeListOverride: PodcastEpisodeListOverride(filter: .unplayed, hidesQueuedEpisodes: true)
        )
        let otherShow = AppRoute.podcastDetail(feedURL: "https://example.com/other.xml")

        #expect(plain != fromInbox)
        #expect(plain.opensSameScreen(as: fromInbox))
        #expect(fromInbox.opensSameScreen(as: plain))
        #expect(!plain.opensSameScreen(as: otherShow))
    }
}
