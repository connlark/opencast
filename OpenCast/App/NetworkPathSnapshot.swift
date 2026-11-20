import Network

nonisolated struct NetworkPathSnapshot: Equatable, Sendable {
    /// Fails closed, so nothing automatic starts on a guess.
    static let unavailable = NetworkPathSnapshot(isSatisfied: false, isExpensive: true, isConstrained: true)

    var isSatisfied: Bool
    var isExpensive: Bool
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

    var allowsAutomaticDownloads: Bool {
        isSatisfied && !isExpensive && !isConstrained
    }
}
