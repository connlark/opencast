/// Raw values persist; an older build reads an unknown one as generic.
nonisolated enum EpisodeAnalysisFailureKind: String, CaseIterable {
    case generic
    case capExceeded
    case insufficientSeconds
    case serviceUnavailable
    case timedOut
    case interrupted
    case validationExhausted
    case providerRejectedKey
    case providerLimited
    case providerDailyLimit
    /// Free tier, and no handover window is open.
    case providerFreeTier
    /// Free tier, and the trial service could not take the run now; waiting can help.
    case providerFreeTierRetry
    /// Free tier, and the run exceeds the trial's run bound; waiting does not help.
    case providerFreeTierRunBound
    case providerUnavailable
    /// One case per `AnalysisKeyRequiredReason`, so the reason survives a relaunch.
    case keyRequiredNoKey
    case keyRequiredTrialExhausted
    case keyRequiredTrialPaused
    case keyRequiredTrialRunBound
    case keyRequiredProxyUnavailable
    case keyRequiredKeychainUnreadable

    init(keyRequired reason: AnalysisKeyRequiredReason) {
        self = switch reason {
        case .noKey: .keyRequiredNoKey
        case .trialExhausted: .keyRequiredTrialExhausted
        case .trialPaused: .keyRequiredTrialPaused
        case .trialRunBound: .keyRequiredTrialRunBound
        case .proxyUnavailable: .keyRequiredProxyUnavailable
        case .keychainUnreadable: .keyRequiredKeychainUnreadable
        }
    }

    /// A run's recorded message carries its code for Diagnostics, so without card copy the queue
    /// would show the code. Listed in full so a new kind has to choose.
    var passUsesCardCopy: Bool {
        switch self {
        case .generic, .insufficientSeconds:
            false
        case .capExceeded, .serviceUnavailable, .timedOut, .interrupted, .validationExhausted,
             .providerRejectedKey, .providerLimited, .providerDailyLimit, .providerFreeTier,
             .providerFreeTierRetry, .providerFreeTierRunBound, .providerUnavailable,
             .keyRequiredNoKey, .keyRequiredTrialExhausted, .keyRequiredTrialPaused,
             .keyRequiredTrialRunBound, .keyRequiredProxyUnavailable, .keyRequiredKeychainUnreadable:
            true
        }
    }

    var keyRequiredReason: AnalysisKeyRequiredReason? {
        switch self {
        case .keyRequiredNoKey: .noKey
        case .keyRequiredTrialExhausted: .trialExhausted
        case .keyRequiredTrialPaused: .trialPaused
        case .keyRequiredTrialRunBound: .trialRunBound
        case .keyRequiredProxyUnavailable: .proxyUnavailable
        case .keyRequiredKeychainUnreadable: .keychainUnreadable
        case .generic, .capExceeded, .insufficientSeconds, .serviceUnavailable, .timedOut, .interrupted,
             .validationExhausted, .providerRejectedKey, .providerLimited, .providerDailyLimit,
             .providerFreeTier, .providerFreeTierRetry, .providerFreeTierRunBound, .providerUnavailable:
            nil
        }
    }
}
