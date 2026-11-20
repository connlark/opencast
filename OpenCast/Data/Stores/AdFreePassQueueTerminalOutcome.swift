enum AdFreePassQueueTerminalOutcome: Equatable {
    case drained(completedCount: Int, failedCount: Int)
    case interrupted
    case remoteParked(RemoteTranscriptionJobExit)
    case cloudUserCancelled
    case awaitingConsent
}
