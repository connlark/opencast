struct EpisodeUpNextMenuState: Equatable {
    let isCurrentEpisode: Bool
    let isQueued: Bool

    var canEnqueue: Bool {
        !isCurrentEpisode
    }
}
