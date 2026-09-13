import Foundation

nonisolated struct OpenCastEntityCatalog: Sendable {
    static let queryLimit = 100
    static let episodesPerShow = 100
    let shows: [OpenCastPodcastEntity]
    let episodes: [OpenCastEpisodeEntity]

    @MainActor
    init(library: LibraryStore) {
        shows = library.subscriptions.filter { library.activePodcastIDs.contains($0.feedURL) }
            .map { OpenCastPodcastEntity(id: $0.feedURL, title: $0.title) }
            .sorted { ($0.title, $0.id) < ($1.title, $1.id) }
        episodes = shows.flatMap { show in
            library.episodes(forPodcastID: show.id).sorted(by: Self.newestFirst)
                .prefix(Self.episodesPerShow).map { OpenCastEpisodeEntity(episode: $0, show: show) }
        }
    }

    static func newestFirst(_ lhs: EpisodeListItemSnapshot, _ rhs: EpisodeListItemSnapshot) -> Bool {
        if lhs.publishedAt != rhs.publishedAt {
            return (lhs.publishedAt ?? .distantPast) > (rhs.publishedAt ?? .distantPast)
        }
        return lhs.episodeID < rhs.episodeID
    }
}
