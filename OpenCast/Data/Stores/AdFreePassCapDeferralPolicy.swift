/// Decision 10: while the queue is cap-deferred, at most one probe per
/// foreground session (the head item's analysis call is the probe); the
/// probed flag resets on each background→foreground cycle; a manual tap on
/// the deferred episode always probes.
struct AdFreePassCapDeferralPolicy {
    enum Trigger: Equatable {
        case sceneActivated
        case refreshCompleted
        case manualTap
    }

    var queueState: AdFreePassQueueState
    var hasProbedThisForegroundSession: Bool
    var trigger: Trigger

    var shouldProbe: Bool {
        guard queueState == .capDeferred else {
            return false
        }

        switch trigger {
        case .manualTap:
            return true
        case .sceneActivated, .refreshCompleted:
            return !hasProbedThisForegroundSession
        }
    }
}
