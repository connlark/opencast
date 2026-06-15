import SwiftUI

struct RouteDestinationView: View {
    let route: AppRoute
    var selectsEpisodeDetailOnPlay = false
    var onRouteInvalidated: () -> Void = {}
    var onOpenEpisode: (String) -> Void = { _ in }

    var body: some View {
        switch route {
        case .podcastDetail(let feedURL):
            PodcastDetailView(
                feedURL: feedURL,
                onUnsubscribe: onRouteInvalidated,
                onOpenEpisode: onOpenEpisode,
                selectsEpisodeDetailOnPlay: selectsEpisodeDetailOnPlay
            )
        case .episodeDetail(let id):
            EpisodeDetailView(episodeID: id)
        }
    }
}

extension View {
    func withOpenCastDestinations(
        onOpenEpisode: @escaping (String) -> Void = { _ in },
        selectsEpisodeDetailOnPlay: Bool = false
    ) -> some View {
        navigationDestination(for: AppRoute.self) { route in
            RouteDestinationView(
                route: route,
                selectsEpisodeDetailOnPlay: selectsEpisodeDetailOnPlay,
                onOpenEpisode: onOpenEpisode
            )
        }
    }
}
