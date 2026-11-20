nonisolated struct CarPlayPlaylistRow: Identifiable, Equatable, Sendable {
    let playlistID: String
    let title: String
    let detailText: String?
    let artworkURL: String?
    let symbolName: String?

    var id: String {
        playlistID
    }
}
