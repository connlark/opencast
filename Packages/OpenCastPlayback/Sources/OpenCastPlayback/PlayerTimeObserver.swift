// AVPlayer returns an opaque token that is only stored for main-actor removal.
struct PlayerTimeObserver: @unchecked Sendable {
    let token: Any
}
