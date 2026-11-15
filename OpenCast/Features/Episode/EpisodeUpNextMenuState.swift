/// Play Next / Play Last for one episode. The episode in the player, playing
/// or paused, never joins the queue behind itself; a queued one can be queued
/// again, which moves it.
struct EpisodeUpNextMenuState: Equatable {
    let isCurrentEpisode: Bool
    let isQueued: Bool

    var canEnqueue: Bool {
        !isCurrentEpisode
    }
}
