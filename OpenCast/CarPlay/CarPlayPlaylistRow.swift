nonisolated struct CarPlayPlaylistRow: Identifiable, Equatable, Sendable {
    let playlistID: String
    let title: String
    let detailText: String?
    /// A manual playlist's first cover show artwork, or a smart playlist's
    /// most dominant matched show's.
    let artworkURL: String?
    /// A smart playlist's stored symbol, or a manual playlist's fallback
    /// glyph, when it has no cover artwork.
    let symbolName: String?

    var id: String {
        playlistID
    }
}
