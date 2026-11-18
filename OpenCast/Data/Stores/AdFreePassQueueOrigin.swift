enum AdFreePassQueueOrigin: String, Equatable {
    case manual
    case auto
    /// A new episode a show's automatic download brought in.
    case prepared

    /// Queued by a play or a new download rather than by a tap.
    var isUnattended: Bool {
        self != .manual
    }
}
