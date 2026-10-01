nonisolated struct OpenCastPlaylistShortcutParameters: Equatable {
    let namesByID: [String: String]

    init(playlists: [PlaylistSummary]) {
        namesByID = Dictionary(playlists.map { ($0.playlistID, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
}
