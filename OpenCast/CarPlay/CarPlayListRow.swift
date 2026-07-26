nonisolated enum CarPlayListRow: Equatable, Sendable {
    static let showMoreTitle = "Show More"

    case episode(CarPlayEpisodeRow)
    case podcast(CarPlayPodcastRow)
    case showMore
}
