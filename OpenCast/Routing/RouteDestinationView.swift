import SwiftUI

struct RouteDestinationView: View {
    let route: AppRoute
    var onOpenEpisode: (String) -> Void = { _ in }

    var body: some View {
        switch route {
        case .podcastDetail(let feedURL):
            PodcastDetailView(
                feedURL: feedURL,
                onOpenEpisode: onOpenEpisode
            )
        case .episodeDetail(let id):
            EpisodeDetailView(episodeID: id)
        case .episodeTranscript(let id):
            EpisodeTranscriptView(episodeID: id)
        case .adDetectionQueue:
            AdDetectionQueueView()
        }
    }
}

extension View {
    func withOpenCastDestinations(
        onOpenEpisode: @escaping (String) -> Void = { _ in }
    ) -> some View {
        navigationDestination(for: AppRoute.self) { route in
            RouteDestinationView(
                route: route,
                onOpenEpisode: onOpenEpisode
            )
        }
    }
}
