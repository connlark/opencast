enum AdFreePassQueueState: Equatable {
    case idle
    case running
    case pausedInterrupted
    case awaitingModelConsent
    case capDeferred
}
