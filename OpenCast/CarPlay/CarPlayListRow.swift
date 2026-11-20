nonisolated enum CarPlayListRow: Equatable, Sendable {
    static let showMoreTitle = "Show More"
    static let playlistsTitle = "Playlists"

    case episode(CarPlayEpisodeRow)
    case podcast(CarPlayPodcastRow)
    case playlists
    case playlist(CarPlayPlaylistRow)
    case showMore
}
