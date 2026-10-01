/// Whether the listener typed a request or asked for suggested groups.
nonisolated enum PlaylistOrganizerMode: String, Equatable, Sendable {
    case prompted
    case unprompted
}
