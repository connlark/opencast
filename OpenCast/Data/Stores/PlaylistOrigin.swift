/// Who drafted a playlist. AI-drafted playlists are ordinary manual
/// playlists; the origin is kept so the UI can label them. The raw value is
/// persisted on `PlaylistRecord`.
nonisolated enum PlaylistOrigin: String, Codable, Sendable {
    case user
    case ai
}
