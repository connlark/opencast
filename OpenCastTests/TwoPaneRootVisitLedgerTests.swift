import SwiftUI
import Testing
@testable import OpenCast

@MainActor
@Suite("Two-pane root visit ledger")
struct TwoPaneRootVisitLedgerTests {
    private static let feed = "https://example.com/feed.xml"
    private static let inboxOverride = PodcastEpisodeListOverride(filter: .unplayed, hidesQueuedEpisodes: true)
    private static let otherOverride = PodcastEpisodeListOverride(filter: .downloaded, hidesQueuedEpisodes: true)
    private static let showFromInbox = AppRoute.podcastDetail(feedURL: feed, episodeListOverride: inboxOverride)
    private static let showFromInboxOther = AppRoute.podcastDetail(feedURL: feed, episodeListOverride: otherOverride)
    private static let episode = AppRoute.episodeDetail(id: "episode-1")

    @MainActor
    private final class Root {
        let state = TwoPaneRootVisitState()
        var container = TwoPaneRootContainer.split
        var path: [AppRoute] = []
        private var token = TwoPaneRootWriterToken()

        private var pathBinding: Binding<[AppRoute]> {
            Binding(get: { self.path }, set: { self.path = $0 })
        }

        var current: TwoPaneRootVisitScope {
            let kind: TwoPaneRootWriter.Kind = container == .split ? .detail(head: path.first) : .stack
            let containerBinding = Binding(get: { self.container }, set: { self.container = $0 })
            return TwoPaneRootWriter.make(kind, token: token, path: pathBinding, container: containerBinding, section: "test")
                .visitScope(state)
        }

        func setPath(_ newPath: [AppRoute]) {
            path = newPath
            state.retainVisits(in: newPath)
        }

        // A switch: the other container, the same path, a new host.
        func switchContainer() {
            container = container == .split ? .stack : .split
            token = TwoPaneRootWriterToken()
            state.retainVisits(in: path)
        }

        func update(_ route: AppRoute, in scope: TwoPaneRootVisitScope, _ change: (inout PodcastDetailVisit) -> Void) {
            var visit = scope.podcastDetailVisit(for: route) ?? PodcastDetailVisit(route: route)
            change(&visit)
            scope.setPodcastDetailVisit(visit, for: route)
        }

        func visit(_ route: AppRoute) -> PodcastDetailVisit? {
            current.podcastDetailVisit(for: route)
        }
    }

    @Test("Picking a filter ends the Inbox override, and a switch either way does not bring it back", arguments: [
        TwoPaneRootContainer.split, .stack
    ])
    func filterPickSurvivesSwitches(startingIn container: TwoPaneRootContainer) {
        let root = Root()
        root.container = container
        root.setPath([Self.showFromInbox])
        root.update(Self.showFromInbox, in: root.current) { $0.episodeListOverride = nil }

        root.switchContainer()
        #expect(root.visit(Self.showFromInbox)?.episodeListOverride == nil)
        root.switchContainer()
        #expect(root.visit(Self.showFromInbox)?.episodeListOverride == nil)
    }

    @Test("The same show under another override is another visit")
    func sameShowOtherOverride() {
        let root = Root()
        root.setPath([Self.showFromInbox])
        root.update(Self.showFromInbox, in: root.current) { $0.episodeListOverride = nil }
        // A sidebar activation of the same show from a re-filtered Inbox.
        root.setPath([Self.showFromInboxOther])
        root.switchContainer()
        #expect(root.visit(Self.showFromInboxOther)?.episodeListOverride == Self.otherOverride)
        // Opening the first route again starts that visit afresh.
        root.setPath([Self.showFromInbox])
        #expect(root.visit(Self.showFromInbox)?.episodeListOverride == Self.inboxOverride)
    }

    @Test("A typed search survives a switch either way with the same query, mode and request", arguments: [
        TwoPaneRootContainer.split, .stack
    ])
    func searchSurvivesSwitches(startingIn container: TwoPaneRootContainer) {
        let root = Root()
        root.container = container
        root.setPath([Self.showFromInbox])
        let page = root.current
        root.update(Self.showFromInbox, in: page) { $0.search = PodcastDetailVisit.Search() }
        root.update(Self.showFromInbox, in: page) {
            $0.search?.query = "deterministic"
            $0.search?.mode = .fullText
        }
        let before = root.visit(Self.showFromInbox)

        root.switchContainer()
        // The outgoing page's search ends as it is torn down: its write is
        // dropped, so the rebuilt page finds the visit's search.
        root.update(Self.showFromInbox, in: page) { $0.search = nil }
        let after = root.visit(Self.showFromInbox)
        #expect(after == before)
        #expect(after?.search?.query == "deterministic")
        #expect(after?.search?.mode == .fullText)
        // The same query, mode and episodes are the same request, hence the
        // same results.
        let episodes: [EpisodeListItemSnapshot] = []
        #expect(
            EpisodeSearchRequestKey(episodes: episodes, query: before?.search?.query ?? "", mode: before?.search?.mode ?? .episodes)
                == EpisodeSearchRequestKey(episodes: episodes, query: after?.search?.query ?? "", mode: after?.search?.mode ?? .episodes)
        )

        // Back the other way, and the user's own Cancel still ends it.
        root.switchContainer()
        #expect(root.visit(Self.showFromInbox)?.search?.query == "deterministic")
        root.update(Self.showFromInbox, in: root.current) { $0.search = nil }
        #expect(root.visit(Self.showFromInbox)?.search == nil)
    }

    @Test("The Notes page's query survives a switch either way; the outgoing page's write is dropped; the visit ends with the path", arguments: [
        TwoPaneRootContainer.split, .stack
    ])
    func notesQuerySurvivesSwitches(startingIn container: TwoPaneRootContainer) {
        let root = Root()
        root.container = container
        root.setPath([.notes])
        let page = root.current
        page.setNotesSearchQuery("chapter", for: .notes)
        #expect(root.current.notesSearchQuery(for: .notes) == "chapter")

        root.switchContainer()
        // The outgoing page's field empties as it is torn down: dropped.
        page.setNotesSearchQuery("", for: .notes)
        #expect(root.current.notesSearchQuery(for: .notes) == "chapter")
        root.switchContainer()
        #expect(root.current.notesSearchQuery(for: .notes) == "chapter")

        // Returning from a nested page keeps it; leaving Notes ends it.
        root.setPath([.notes, Self.episode])
        root.setPath([.notes])
        #expect(root.current.notesSearchQuery(for: .notes) == "chapter")
        root.setPath([])
        root.setPath([.notes])
        #expect(root.current.notesSearchQuery(for: .notes) == "")
    }
}
