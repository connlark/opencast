/// The playlist current playback came from, joined with its live summary so
/// a rename shows at once and a deleted playlist yields no source.
nonisolated struct PlaylistPlaybackSource: Equatable, Sendable {
    let playlistID: String
    let name: String
}
