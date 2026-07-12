struct AdFreePassQueueItemOutcome: Identifiable, Equatable {
    enum Kind: Equatable {
        case completed(zoneCount: Int)
        case failed(message: String)
    }

    let episodeID: String
    let episodeTitle: String
    let artworkURL: String?
    let kind: Kind

    var id: String {
        episodeID
    }
}
