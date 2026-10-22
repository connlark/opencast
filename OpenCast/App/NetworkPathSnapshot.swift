import Network

/// The parts of a network path the app acts on.
nonisolated struct NetworkPathSnapshot: Equatable, Sendable {
    /// The fallback when no path could be read: offline, metered and
    /// constrained, so nothing automatic starts on a guess.
    static let unavailable = NetworkPathSnapshot(isSatisfied: false, isExpensive: true, isConstrained: true)

    var isSatisfied: Bool
    /// Cellular or a personal hotspot.
    var isExpensive: Bool
    /// Low Data Mode.
    var isConstrained: Bool

    init(isSatisfied: Bool, isExpensive: Bool, isConstrained: Bool) {
        self.isSatisfied = isSatisfied
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    init(_ path: NWPath) {
        self.init(
            isSatisfied: path.status == .satisfied,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }

    /// Wi-Fi Only for automatic downloads: Low Data Mode counts as not
    /// Wi-Fi, like cellular.
    var allowsAutomaticDownloads: Bool {
        isSatisfied && !isExpensive && !isConstrained
    }
}
