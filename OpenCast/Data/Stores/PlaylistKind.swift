/// The raw value is persisted on `PlaylistRecord`.
nonisolated enum PlaylistKind: String, Codable, Sendable {
    case manual
    case smart
}
