/// Why a feature cannot run without the listener's own key.
nonisolated enum AnalysisKeyRequiredReason: String, Sendable, Hashable, Codable, CaseIterable {
    /// No saved key has an entry for the feature, and no trial route applies.
    case noKey
    /// The install's free analyses are used.
    case trialExhausted
    /// The trial is paused for now.
    case trialPaused
    /// The episode needs more than one free analysis covers.
    case trialRunBound
    /// The trial service could not be reached, this build has no trial
    /// route, or this device cannot attest.
    case proxyUnavailable
    /// The Keychain could not be read, so whether a key exists is unknown.
    /// Never treated as "no key": a run never moves to the trial for it.
    case keychainUnreadable

    /// What the key screen says about the trial for this reason, given the
    /// last status the trial service reported.
    func trialStatus(lastKnown: AnalysisTrialStatus?) -> AnalysisTrialStatus {
        switch self {
        case .trialExhausted: .exhausted
        case .noKey, .trialPaused, .trialRunBound, .proxyUnavailable, .keychainUnreadable: lastKnown ?? .exhausted
        }
    }
}
