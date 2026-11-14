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

    @Test("An override lists every episode by archive state unless the Inbox view it came from says otherwise")
    func overrideArchiveScopeDefaultsToAllAndTakesPartInEquality() {
        let unset = PodcastEpisodeListOverride(filter: .unplayed, hidesQueuedEpisodes: true)
        let hiding = PodcastEpisodeListOverride(filter: .unplayed, hidesQueuedEpisodes: true, archiveScope: .hidingArchived)
        let only = PodcastEpisodeListOverride(filter: .unplayed, hidesQueuedEpisodes: true, archiveScope: .onlyArchived)

        #expect(unset.archiveScope == .all)
        #expect(unset == PodcastEpisodeListOverride(filter: .unplayed, hidesQueuedEpisodes: true, archiveScope: .all))
        #expect(hiding.archiveScope == .hidingArchived)
        #expect(only.archiveScope == .onlyArchived)
        #expect(unset != hiding)
        #expect(unset != only)
        #expect(hiding != only)
        #expect(Set([unset, hiding, only, unset]).count == 3)
    }

    @Test("Other routes are the same screen only when equal")
    func otherRoutesCompareByEquality() {
        #expect(AppRoute.episodeDetail(id: "a").opensSameScreen(as: .episodeDetail(id: "a")))
        #expect(!AppRoute.episodeDetail(id: "a").opensSameScreen(as: .episodeDetail(id: "b")))
        #expect(!AppRoute.playlists.opensSameScreen(as: .adDetectionQueue))
    }
}
