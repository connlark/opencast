nonisolated struct CarPlayEpisodeRow: Identifiable, Equatable, Sendable {
    let episodeID: String
    let title: String
    let detailText: String?
    let artworkURL: String?
    let playbackProgress: Double?
    let isPlaying: Bool
    let isDownloaded: Bool
    let sourcePlaylistID: String?

    var id: String {
        episodeID
    }
}
