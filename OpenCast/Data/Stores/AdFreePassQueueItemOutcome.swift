struct AdFreePassQueueItemOutcome: Identifiable, Equatable {
    enum Kind: Equatable {
        case completed(zoneCount: Int)
        case failed(message: String)
        /// Cloud detection couldn't run; finished rows for this kind offer
        /// "Detect on this device instead".
        case cloudUnavailable(message: String)
        /// Ad detection needed the listener's own key (no key, the trial
        /// used or paused, its service unreachable, the Keychain locked).
        /// The episode's analysis record keeps the reason across launches.
        case keyRequired(AnalysisKeyRequiredReason)
    }

    let episodeID: String
    let episodeTitle: String
    let artworkURL: String?
    let kind: Kind
    /// Who delivers this item's completion. A cloud item copies the owner
    /// its remote job run snapshotted before the reference was cleared;
    /// on-device items, and cloud items that never reached a run, are local.
    let completionDeliveryOwner: JobCompletionDeliveryOwner

    var id: String {
        episodeID
    }
}
