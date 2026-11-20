/// The raw value is persisted on `PlaylistRecord`.
nonisolated enum PlaylistOrigin: String, Codable, Sendable {
    case user
    case ai
}
