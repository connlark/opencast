nonisolated struct CarPlayEpisodeRow: Identifiable, Equatable, Sendable {
    let episodeID: String
    let title: String
    let detailText: String?
    let artworkURL: String?
    let playbackProgress: Double?
    let isPlaying: Bool
    let isDownloaded: Bool

    var id: String {
        episodeID
    }
}
