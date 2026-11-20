import OpenCastAnalysis
import OpenCastAnalysisProviders

/// Decided before the run's record is written; the key is held only for the run that resolved it.
nonisolated struct AnalysisRouteResolution: Sendable {
    let feature: AnalysisFeature
    let route: AnalysisRoute
    /// `nil` only for `keyRequired`.
    let policy: AnalysisRoutePolicy?
    /// Set only for `direct`.
    let key: AnalysisProviderKey?
    let resumingRunID: String?
    /// Set only for `trial`.
    let trialExchange: (any AnalysisTrialProxyExchange)?
    /// Ad detection on a Google key inside the handover window: a free-tier
    /// answer ends the direct attempt and the trial service can take over.
    var freeTierHandover = false

    var provider: AnalysisProvider? {
        switch route {
        case .direct(let provider): provider
        case .trial: .google
        case .keyRequired: nil
        }
    }

    var keyRequiredReason: AnalysisKeyRequiredReason? {
        if case .keyRequired(let reason) = route { reason } else { nil }
    }

    static func keyRequired(_ reason: AnalysisKeyRequiredReason, feature: AnalysisFeature) -> Self {
        AnalysisRouteResolution(feature: feature, route: .keyRequired(reason), policy: nil, key: nil, resumingRunID: nil, trialExchange: nil)
    }
}
