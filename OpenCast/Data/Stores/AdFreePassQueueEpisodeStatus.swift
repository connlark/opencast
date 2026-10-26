enum AdFreePassQueueEpisodeStatus: Equatable {
    case notQueued
    case queued(ahead: Int)
    case running
    case completed(zoneCount: Int)
    case failed(message: String)
    /// A cloud detect pass could not run (no credits, service off); the
    /// surfaces offer a one-tap on-device detect instead.
    case cloudUnavailable(message: String)
    /// Ad detection needed the listener's own key; the surfaces say how to
    /// add one.
    case keyRequired(AnalysisKeyRequiredReason)
    /// A cloud item stopped polling while its server job kept running; the
    /// surfaces offer Resume (same job) and Cancel (the user cancel).
    case remoteParked(RemoteTranscriptionJobExit)
}
