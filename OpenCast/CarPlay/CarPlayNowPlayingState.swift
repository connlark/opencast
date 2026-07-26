/// What the car needs to know about the transport: which episode is loaded, and
/// whether it is actually producing audio. `CPListItem.isPlaying` renders a
/// "currently playing" icon, so a loaded-but-paused episode must not claim it.
nonisolated struct CarPlayNowPlayingState: Equatable, Sendable {
    static let idle = CarPlayNowPlayingState(episodeID: nil, isPlaying: false)

    let episodeID: String?
    let isPlaying: Bool

    func isActivelyPlaying(_ episodeID: String) -> Bool {
        isPlaying && self.episodeID == episodeID
    }
}
