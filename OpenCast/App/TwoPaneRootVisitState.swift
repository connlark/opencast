import SwiftUI

/// The show page's per-visit settings: what it lists and what it searches.
///
/// A show opened from the Group by Podcast Inbox carries the Inbox's filter
/// and Hide Up Next in its route for that visit only
/// (`AppRoute.podcastDetail(feedURL:episodeListOverride:)`); picking a
/// filter on the page ends them and Show Hidden Episodes turns Hide Up Next
/// off. The page's episode search (shown or not, its query and mode) decides
/// what the page lists too.
struct PodcastDetailVisit: Equatable {
    /// The page's episode search while it is shown.
    struct Search: Equatable {
        var query = ""
        var mode = EpisodeSearchMode.episodes
    }

    var episodeListOverride: PodcastEpisodeListOverride?
    /// Nil while the search is hidden.
    var search: Search?

    /// A new visit: the route's own override, no search.
    init(route: AppRoute) {
        if case .podcastDetail(_, let override) = route {
            episodeListOverride = override
        }
    }
}

/// The visits of one section's pages, kept above a two-pane root's
/// containers: a switch between them (a fold, a rotation) rebuilds every
/// page, and the route keeps its payload (it is the page's identity), so a
/// rebuilt page would otherwise start its visit again from the route.
///
/// A visit is keyed by its complete route and lasts while the section's path
/// still holds that route: replacing the path, popping the page or clearing
/// the path ends it, and opening the route again starts afresh. A page
/// cannot tell which of several equal routes it is, so the ledger keeps a
/// visit only while its route appears once in the path; pages whose route
/// appears more than once keep their visits to themselves, each its own.
struct TwoPaneRootVisitLedger: Equatable {
    private var podcastDetailVisits: [AppRoute: PodcastDetailVisit] = [:]
    /// The Notes page's search query, per visit, as the show page's search.
    private var notesSearchQueries: [AppRoute: String] = [:]

    func podcastDetailVisit(for route: AppRoute) -> PodcastDetailVisit {
        podcastDetailVisits[route] ?? PodcastDetailVisit(route: route)
    }

    /// The visit of the one page that shows `route` in `path`, or nil when
    /// the path holds the route more than once (or not at all).
    func podcastDetailVisit(for route: AppRoute, in path: [AppRoute]) -> PodcastDetailVisit? {
        Self.holdsOnce(route, in: path) ? podcastDetailVisit(for: route) : nil
    }

    static func holdsOnce(_ route: AppRoute, in path: [AppRoute]) -> Bool {
        path.count { $0 == route } == 1
    }

    mutating func setPodcastDetailVisit(_ visit: PodcastDetailVisit, for route: AppRoute) {
        podcastDetailVisits[route] = visit
    }

    func notesSearchQuery(for route: AppRoute) -> String {
        notesSearchQueries[route] ?? ""
    }

    mutating func setNotesSearchQuery(_ query: String, for route: AppRoute) {
        notesSearchQueries[route] = query
    }

    /// Ends every visit whose route the path no longer holds.
    mutating func retainVisits(in path: [AppRoute]) {
        guard !podcastDetailVisits.isEmpty || !notesSearchQueries.isEmpty else {
            return
        }
        let routes = Set(path)
        podcastDetailVisits = podcastDetailVisits.filter { routes.contains($0.key) }
        notesSearchQueries = notesSearchQueries.filter { routes.contains($0.key) }
    }
}

/// One section's visit ledger, owned by its `TwoPaneRoot` above both
/// containers.
@Observable
final class TwoPaneRootVisitState {
    private(set) var ledger = TwoPaneRootVisitLedger()

    func podcastDetailVisit(for route: AppRoute) -> PodcastDetailVisit {
        ledger.podcastDetailVisit(for: route)
    }

    func setPodcastDetailVisit(_ visit: PodcastDetailVisit, for route: AppRoute) {
        guard visit != ledger.podcastDetailVisit(for: route) else {
            return
        }
        ledger.setPodcastDetailVisit(visit, for: route)
    }

    func setNotesSearchQuery(_ query: String, for route: AppRoute) {
        guard query != ledger.notesSearchQuery(for: route) else {
            return
        }
        ledger.setNotesSearchQuery(query, for: route)
    }

    func retainVisits(in path: [AppRoute]) {
        var updated = ledger
        updated.retainVisits(in: path)
        if updated != ledger {
            ledger = updated
        }
    }
}

/// The ledger as one hosting stack's pages see it (`TwoPaneRootWriter`).
/// Reads reach the ledger while the page's route appears once in the path;
/// writes land only while that stack is current, so a page torn down by a
/// switch or a new detail root (whose search ends as it goes) cannot end the
/// visit the rebuilt page is about to show. Where there is no visit (no
/// two-pane root, or a route the path holds twice) a page keeps its visit in
/// its own state.
struct TwoPaneRootVisitScope {
    let state: TwoPaneRootVisitState
    /// For the log only.
    var section = ""
    /// The section path, read live.
    let path: () -> [AppRoute]
    let isCurrent: () -> Bool

    func podcastDetailVisit(for route: AppRoute) -> PodcastDetailVisit? {
        state.ledger.podcastDetailVisit(for: route, in: path())
    }

    func setPodcastDetailVisit(_ visit: PodcastDetailVisit, for route: AppRoute) {
        guard isCurrent(), TwoPaneRootVisitLedger.holdsOnce(route, in: path()) else {
            TwoPaneRootLog.ignoredWrite("visit", section: section)
            return
        }
        state.setPodcastDetailVisit(visit, for: route)
    }

    /// The Notes page's query while its route appears once in the path.
    func notesSearchQuery(for route: AppRoute) -> String? {
        TwoPaneRootVisitLedger.holdsOnce(route, in: path()) ? state.ledger.notesSearchQuery(for: route) : nil
    }

    func setNotesSearchQuery(_ query: String, for route: AppRoute) {
        guard isCurrent(), TwoPaneRootVisitLedger.holdsOnce(route, in: path()) else {
            TwoPaneRootLog.ignoredWrite("visit", section: section)
            return
        }
        state.setNotesSearchQuery(query, for: route)
    }
}

extension EnvironmentValues {
    @Entry var twoPaneRootVisit: TwoPaneRootVisitScope?
}
