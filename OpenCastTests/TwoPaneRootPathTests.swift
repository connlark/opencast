import Testing
@testable import OpenCast

@MainActor
@Suite("Two-pane root path contract")
struct TwoPaneRootPathTests {
    private static let feed = "https://example.com/feed.xml"
    private static let otherFeed = "https://example.com/other.xml"
    private static let inboxOverride = PodcastEpisodeListOverride(filter: .unplayed, hidesQueuedEpisodes: true)
    private static let otherOverride = PodcastEpisodeListOverride(filter: .all, hidesQueuedEpisodes: false)

    private static let show = AppRoute.podcastDetail(feedURL: feed)
    private static let showFromInbox = AppRoute.podcastDetail(feedURL: feed, episodeListOverride: inboxOverride)
    private static let showFromInboxOther = AppRoute.podcastDetail(feedURL: feed, episodeListOverride: otherOverride)
    private static let otherShow = AppRoute.podcastDetail(feedURL: otherFeed)
    private static let episode = AppRoute.episodeDetail(id: "episode-1")
    private static let transcript = AppRoute.episodeTranscript(id: "episode-1")

    @Test("A root activation replaces the path in the split and pushes in the stack")
    func rootActivation() {
        // Split: from empty, from one, from deep, and reselecting the head.
        #expect(TwoPaneRootPath.openingFromRoot(Self.show, in: [], container: .split) == [Self.show])
        #expect(TwoPaneRootPath.openingFromRoot(Self.otherShow, in: [Self.show], container: .split) == [Self.otherShow])
        #expect(
            TwoPaneRootPath.openingFromRoot(.notes, in: [Self.show, Self.episode, Self.transcript], container: .split)
                == [.notes]
        )
        #expect(TwoPaneRootPath.openingFromRoot(Self.show, in: [Self.show, Self.episode], container: .split) == [Self.show])
        // Stack: a push.
        #expect(TwoPaneRootPath.openingFromRoot(Self.show, in: [], container: .stack) == [Self.show])
        #expect(
            TwoPaneRootPath.openingFromRoot(Self.episode, in: [Self.show], container: .stack) == [Self.show, Self.episode]
        )
    }

    @Test("An obsolete detail stack never overwrites a newer path")
    func obsoleteDetailWrites() {
        // The head was replaced: the old detail stack's teardown write is dropped.
        #expect(
            TwoPaneRootPath.writingDetailSuffix([], forHead: Self.show, into: [Self.otherShow], currentContainer: .split)
                == nil
        )
        // The complete route is the identity: another Inbox override is another root.
        #expect(
            TwoPaneRootPath.writingDetailSuffix(
                [],
                forHead: Self.showFromInbox,
                into: [Self.showFromInboxOther, Self.episode],
                currentContainer: .split
            ) == nil
        )
        // The path was cleared: the placeholder's stack is the current one.
        #expect(
            TwoPaneRootPath.writingDetailSuffix([Self.episode], forHead: Self.show, into: [], currentContainer: .split)
                == nil
        )
        // The split is the outgoing container.
        #expect(
            TwoPaneRootPath.writingDetailSuffix([], forHead: Self.show, into: [Self.show, Self.episode], currentContainer: .stack)
                == nil
        )
    }

    @Test("Under the placeholder a detail write becomes the path")
    func placeholderWrites() {
        #expect(
            TwoPaneRootPath.writingDetailSuffix([Self.show], forHead: nil, into: [], currentContainer: .split)
                == [Self.show]
        )
        // Once a head exists, the placeholder's stack is obsolete.
        #expect(
            TwoPaneRootPath.writingDetailSuffix([], forHead: nil, into: [Self.show], currentContainer: .split) == nil
        )
    }
}
