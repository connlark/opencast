/// What a Make a Playlist turn asks the model to write. `standard` is every
/// first request. `indicesOnly` is the listener's experimental retry after a
/// decline: the model returns episode numbers only and the app names the
/// playlists, so Apple's output check has no model-written words to decline.
nonisolated enum PlaylistOrganizerAnswerStyle: String, Equatable, Sendable {
    case standard
    case indicesOnly
}
