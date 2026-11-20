enum AdFreePassQueueOrigin: String, Equatable {
    case manual
    case auto
    /// A new episode a show's automatic download brought in.
    case prepared

    var isUnattended: Bool {
        self != .manual
    }
}
