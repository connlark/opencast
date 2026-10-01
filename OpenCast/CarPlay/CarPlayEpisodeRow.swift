nonisolated struct CarPlayEpisodeRow: Identifiable, Equatable, Sendable {
    let episodeID: String
    let title: String
    let detailText: String?
    let artworkURL: String?
    let playbackProgress: Double?
    let isPlaying: Bool
    let isDownloaded: Bool
    /// Set on rows in a car playlist list, so a tap plays from that playlist.
    let sourcePlaylistID: String?

    var id: String {
        episodeID
    }
}
