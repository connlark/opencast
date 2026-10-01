nonisolated enum CarPlayListRow: Equatable, Sendable {
    static let showMoreTitle = "Show More"
    static let playlistsTitle = "Playlists"

    case episode(CarPlayEpisodeRow)
    case podcast(CarPlayPodcastRow)
    /// The glyph-and-title row that leads the Library list and pushes the playlists.
    case playlists
    case playlist(CarPlayPlaylistRow)
    case showMore
}
