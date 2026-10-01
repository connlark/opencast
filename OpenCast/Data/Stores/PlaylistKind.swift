/// Whether a playlist stores its own ordered items or evaluates a saved rule.
/// The raw value is persisted on `PlaylistRecord`.
nonisolated enum PlaylistKind: String, Codable, Sendable {
    case manual
    case smart
}
