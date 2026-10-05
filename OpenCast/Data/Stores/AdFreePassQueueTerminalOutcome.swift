enum AdFreePassQueueTerminalOutcome: Equatable {
    case drained(completedCount: Int, failedCount: Int)
    /// On-device work stopped; the copy says the device paused it.
    case interrupted
    /// A cloud item stopped polling while its server job may still be
    /// running; the item waits at the head with this reason.
    case remoteParked(RemoteTranscriptionJobExit)
    /// The person cancelled the running cloud item.
    case cloudUserCancelled
    case awaitingConsent
    case capDeferred
}
