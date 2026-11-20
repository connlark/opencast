struct AdFreePassQueueItemOutcome: Identifiable, Equatable {
    enum Kind: Equatable {
        case completed(zoneCount: Int)
        case failed(message: String)
        case cloudUnavailable(message: String)
        case keyRequired(AnalysisKeyRequiredReason)
    }

    let episodeID: String
    let episodeTitle: String
    let artworkURL: String?
    let kind: Kind
    /// A cloud item copies the owner its run snapshotted; on-device items and cloud items that
    /// never reached a run are local.
    let completionDeliveryOwner: JobCompletionDeliveryOwner
    var origin: AdFreePassQueueOrigin = .manual

    var id: String {
        episodeID
    }
}
