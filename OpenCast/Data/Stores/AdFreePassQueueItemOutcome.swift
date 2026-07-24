struct AdFreePassQueueItemOutcome: Identifiable, Equatable {
    enum Kind: Equatable {
        case completed(zoneCount: Int)
        case failed(message: String)
        /// Cloud detection couldn't run; finished rows for this kind offer
        /// "Detect on this device instead".
        case cloudUnavailable(message: String)
    }

    let episodeID: String
    let episodeTitle: String
    let artworkURL: String?
    let kind: Kind

    var id: String {
        episodeID
    }
}
