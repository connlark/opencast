import SwiftUI

struct PodcastDetailVisit: Equatable {
    struct Search: Equatable {
        var query = ""
        var mode = EpisodeSearchMode.episodes
    }

    var episodeListOverride: PodcastEpisodeListOverride?
    /// Nil while the search is hidden.
    var search: Search?

    init(route: AppRoute) {
        if case .podcastDetail(_, let override) = route {
            episodeListOverride = override
        }
    }
}

/// Kept above the containers because a switch rebuilds every page. A visit
/// lasts while the path holds its route, and is kept here only while the route
/// appears once: a page cannot tell which of several equal routes it is.
struct TwoPaneRootVisitLedger: Equatable {
    private var podcastDetailVisits: [AppRoute: PodcastDetailVisit] = [:]
    private var notesSearchQueries: [AppRoute: String] = [:]

    func podcastDetailVisit(for route: AppRoute) -> PodcastDetailVisit {
        podcastDetailVisits[route] ?? PodcastDetailVisit(route: route)
    }

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

    mutating func retainVisits(in path: [AppRoute]) {
        guard !podcastDetailVisits.isEmpty || !notesSearchQueries.isEmpty else {
            return
        }
        let routes = Set(path)
        podcastDetailVisits = podcastDetailVisits.filter { routes.contains($0.key) }
        notesSearchQueries = notesSearchQueries.filter { routes.contains($0.key) }
    }
}

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

/// Writes land only while this stack is current, so a page torn down by a
/// switch (its search ending as it goes) cannot end the visit the rebuilt page
/// is about to show. Without a visit here, a page keeps it in its own state.
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
