nonisolated struct PlaylistOrganizerRequest: Equatable, Sendable {
    var podcastID: String
    var showTitle: String
    var mode: PlaylistOrganizerMode
    var prompt: String?
}
