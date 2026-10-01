import SwiftUI

struct RouteDestinationView: View {
    let route: AppRoute
    var onOpenEpisode: (String) -> Void = { _ in }
    var onOpenPlaylist: (String) -> Void = { _ in }

    var body: some View {
        switch route {
        case .podcastDetail(let feedURL, let episodeListOverride):
            PodcastDetailView(
                feedURL: feedURL,
                episodeListOverride: episodeListOverride,
                onOpenEpisode: onOpenEpisode
            )
        case .episodeDetail(let id):
            EpisodeDetailView(episodeID: id)
        case .episodeArtwork(let id):
            EpisodeArtworkZoomView(episodeID: id)
        case .episodeTranscript(let id):
            EpisodeTranscriptView(episodeID: id)
        case .adDetectionQueue:
            AdDetectionQueueView()
        case .playlists:
            PlaylistsView(onOpenPlaylist: onOpenPlaylist)
        case .playlistDetail(let id):
            PlaylistDetailView(
                playlistID: id,
                onOpenEpisode: onOpenEpisode
            )
        case .settings(let route):
            SettingsRouteDestinationView(route: route)
        }
    }
}

extension View {
    func withOpenCastDestinations(
        onOpenEpisode: @escaping (String) -> Void = { _ in },
        onOpenPlaylist: @escaping (String) -> Void = { _ in }
    ) -> some View {
        navigationDestination(for: AppRoute.self) { route in
            RouteDestinationView(
                route: route,
                onOpenEpisode: onOpenEpisode,
                onOpenPlaylist: onOpenPlaylist
            )
        }
    }
}
