nonisolated enum AnalysisKeyRequiredReason: String, Sendable, Hashable, Codable, CaseIterable {
    case noKey
    case trialExhausted
    case trialPaused
    /// The episode needs more than one free analysis covers.
    case trialRunBound
    case proxyUnavailable
    /// Never treated as `.noKey`: a run never moves to the trial for it.
    case keychainUnreadable

    func trialStatus(lastKnown: AnalysisTrialStatus?) -> AnalysisTrialStatus {
        switch self {
        case .trialExhausted: .exhausted
        case .noKey, .trialPaused, .trialRunBound, .proxyUnavailable, .keychainUnreadable: lastKnown ?? .exhausted
        }
    }
}
