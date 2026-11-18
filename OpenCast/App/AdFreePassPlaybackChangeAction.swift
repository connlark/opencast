enum AdFreePassPlaybackChangeAction: Equatable {
    case none
    /// Resume a queue held for the lifecycle, if the rule now allows it.
    case resumeLifecycleHold
    /// Wait out the inactive grace, then hold the queue's own unattended
    /// transcription if the rule still does not allow it.
    case holdIfStillIneligible
}
