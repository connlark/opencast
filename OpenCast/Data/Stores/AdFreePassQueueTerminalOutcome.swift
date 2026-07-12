enum AdFreePassQueueTerminalOutcome: Equatable {
    case drained(completedCount: Int, failedCount: Int)
    case interrupted
    case awaitingConsent
    case capDeferred
}
