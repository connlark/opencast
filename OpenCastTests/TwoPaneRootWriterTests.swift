import SwiftUI
import Testing
@testable import OpenCast

/// The writes the two-pane containers make through the bindings, scopes and
/// close actions `TwoPaneRoot` builds (`TwoPaneRootWriter`), held and
/// invoked after the scene moved on: a switch, a new detail root, pruning, a
/// return to an earlier head. A host's lifetime is its token: dropping the
/// last strong reference is what SwiftUI does when the host leaves.
@MainActor
@Suite("Two-pane root writers")
struct TwoPaneRootWriterTests {
    private static let show = AppRoute.podcastDetail(feedURL: "https://example.com/feed.xml")
    private static let otherShow = AppRoute.podcastDetail(feedURL: "https://example.com/other.xml")
    private static let episode = AppRoute.episodeDetail(id: "episode-1")
    private static let transcript = AppRoute.episodeTranscript(id: "episode-1")

    /// The section path and the scene's container, as the tab root holds them.
    @MainActor
    private final class Scene {
        var path: [AppRoute] = []
        var container = TwoPaneRootContainer.split
        let visitState = TwoPaneRootVisitState()

        var pathBinding: Binding<[AppRoute]> {
            Binding(get: { self.path }, set: { self.path = $0 })
        }

        var containerBinding: Binding<TwoPaneRootContainer> {
            Binding(get: { self.container }, set: { self.container = $0 })
        }

        /// As the hosts build their writers.
        func writer(_ kind: TwoPaneRootWriter.Kind, token: TwoPaneRootWriterToken) -> TwoPaneRootWriter {
            TwoPaneRootWriter.make(kind, token: token, path: pathBinding, container: containerBinding, section: "test")
        }
    }

    /// A host: the only owner of its token, as a host's state is.
    @MainActor
    private final class Host {
        let token = TwoPaneRootWriterToken()
    }

    @Test("What a gone host handed out does not keep its token, and writes nothing")
    func retainedCallbacksDoNotKeepTheToken() {
        let scene = Scene()
        scene.path = [Self.show, Self.episode]
        var host: Host? = Host()
        let writer = scene.writer(.detail(head: Self.show), token: host!.token)
        let suffix = writer.detailSuffix
        let scope = writer.visitScope(scene.visitState)
        let close = writer.closeAction(for: Self.show)
        weak var token = host?.token
        #expect(token != nil)

        host = nil
        #expect(token == nil)
        // The same container and head as before: only the host is gone.
        suffix.wrappedValue = []
        close.close()
        var visit = PodcastDetailVisit(route: Self.show)
        visit.search = PodcastDetailVisit.Search(query: "gone", mode: .episodes)
        scope.setPodcastDetailVisit(visit, for: Self.show)
        #expect(scene.path == [Self.show, Self.episode])
        #expect(scene.visitState.podcastDetailVisit(for: Self.show).search == nil)
    }

    @Test("A current detail stack pushes and pops behind its head")
    func currentDetailWrites() {
        let scene = Scene()
        scene.path = [Self.show]
        let token = TwoPaneRootWriterToken()
        let detail = scene.writer(.detail(head: Self.show), token: token).detailSuffix
        #expect(detail.wrappedValue.isEmpty)
        detail.wrappedValue = [Self.episode]
        #expect(scene.path == [Self.show, Self.episode])
        detail.wrappedValue = []
        #expect(scene.path == [Self.show])
        withExtendedLifetime(token) {}
    }

    @Test("A detail stack built for an earlier head writes nothing, even when that head returns")
    func earlierHeadReturns() {
        let scene = Scene()
        scene.path = [Self.show, Self.episode]
        var firstToken: TwoPaneRootWriterToken? = TwoPaneRootWriterToken()
        let first = scene.writer(.detail(head: Self.show), token: firstToken!).detailSuffix

        // A sidebar activation: B replaces A; A's host leaves.
        scene.path = [Self.otherShow]
        first.wrappedValue = []
        #expect(scene.path == [Self.otherShow])
        firstToken = nil

        // A again: a new host for the same head. The first one's retained
        // binding still writes nothing; the new one writes.
        scene.path = [Self.show]
        let secondToken = TwoPaneRootWriterToken()
        let second = scene.writer(.detail(head: Self.show), token: secondToken).detailSuffix
        first.wrappedValue = [Self.transcript]
        #expect(scene.path == [Self.show])
        second.wrappedValue = [Self.episode]
        #expect(scene.path == [Self.show, Self.episode])
        withExtendedLifetime(secondToken) {}
    }

    @Test("An outgoing container's writes are dropped, and stay dropped after a return to it")
    func outgoingContainers() {
        let scene = Scene()
        scene.container = .stack
        scene.path = [Self.show, Self.episode]
        var stackToken: TwoPaneRootWriterToken? = TwoPaneRootWriterToken()
        let stack = scene.writer(.stack, token: stackToken!).stackPath

        // Stack → split: the stack's teardown write is dropped.
        scene.container = .split
        stack.wrappedValue = []
        #expect(scene.path == [Self.show, Self.episode])
        stackToken = nil
        let detailToken = TwoPaneRootWriterToken()
        let detail = scene.writer(.detail(head: Self.show), token: detailToken).detailSuffix

        // Split → stack: the detail stack's writes are dropped, and so are
        // the first stack's, though the container is a stack again.
        scene.container = .stack
        detail.wrappedValue = []
        stack.wrappedValue = []
        #expect(scene.path == [Self.show, Self.episode])
        let newStackToken = TwoPaneRootWriterToken()
        let newStack = scene.writer(.stack, token: newStackToken).stackPath
        newStack.wrappedValue = [Self.show]
        #expect(scene.path == [Self.show])
        withExtendedLifetime((detailToken, newStackToken)) {}
    }

    @Test("Pruning the head rebuilds the detail stack: the old one's writes and visit writes are dropped")
    func pruningRebuildsTheDetailStack() {
        let scene = Scene()
        scene.path = [Self.episode, Self.show]
        let oldToken = TwoPaneRootWriterToken()
        let old = scene.writer(.detail(head: Self.episode), token: oldToken)
        let oldScope = old.visitScope(scene.visitState)
        var searching = oldScope.podcastDetailVisit(for: Self.show) ?? PodcastDetailVisit(route: Self.show)
        searching.search = PodcastDetailVisit.Search(query: "kept", mode: .episodes)
        oldScope.setPodcastDetailVisit(searching, for: Self.show)

        // The episode left the library: the show is the new head.
        scene.path.removeAll { $0 == Self.episode }
        scene.visitState.retainVisits(in: scene.path)
        // The old detail stack's show page ends its search as it goes.
        var ended = searching
        ended.search = nil
        oldScope.setPodcastDetailVisit(ended, for: Self.show)
        old.detailSuffix.wrappedValue = []
        #expect(scene.path == [Self.show])

        let newToken = TwoPaneRootWriterToken()
        let newScope = scene.writer(.detail(head: Self.show), token: newToken).visitScope(scene.visitState)
        #expect(newScope.podcastDetailVisit(for: Self.show)?.search?.query == "kept")
        withExtendedLifetime((oldToken, newToken)) {}
    }

    @Test("The detail root closes only while its stack is current and its route is the head")
    func rootClose() {
        let scene = Scene()
        scene.path = [Self.show]
        var token: TwoPaneRootWriterToken? = TwoPaneRootWriterToken()
        let close = scene.writer(.detail(head: Self.show), token: token!).closeAction(for: Self.show)

        // A feed migration awaiting while the scene switches to the stack and
        // the user goes on: the old close must not clear the newer path.
        scene.container = .stack
        scene.path = [Self.show, Self.episode]
        close.close()
        #expect(scene.path == [Self.show, Self.episode])
        // Back to the split but a new detail stack: still not this close's.
        scene.container = .split
        token = nil
        close.close()
        #expect(scene.path == [Self.show, Self.episode])

        let currentToken = TwoPaneRootWriterToken()
        let current = scene.writer(.detail(head: Self.show), token: currentToken).closeAction(for: Self.show)
        #expect(current.route == Self.show)
        current.close()
        #expect(scene.path.isEmpty)
        withExtendedLifetime(currentToken) {}
    }

    @Test("A page whose route the path holds twice keeps its visit to itself")
    func repeatedRoutes() {
        let scene = Scene()
        scene.container = .stack
        scene.path = [Self.show, Self.episode, Self.show]
        let token = TwoPaneRootWriterToken()
        let scope = scene.writer(.stack, token: token).visitScope(scene.visitState)
        #expect(scope.podcastDetailVisit(for: Self.show) == nil)
        var visit = PodcastDetailVisit(route: Self.show)
        visit.search = PodcastDetailVisit.Search(query: "second", mode: .episodes)
        scope.setPodcastDetailVisit(visit, for: Self.show)
        // Back to one show page: the first page's visit, untouched.
        scene.path = [Self.show]
        scene.visitState.retainVisits(in: scene.path)
        #expect(scope.podcastDetailVisit(for: Self.show)?.search == nil)
        withExtendedLifetime(token) {}
    }
}
