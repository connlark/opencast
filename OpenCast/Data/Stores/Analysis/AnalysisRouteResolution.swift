import OpenCastAnalysis
import OpenCastAnalysisProviders

/// One run's route, decided before its record is written: the route, the
/// policy it runs under, and the key when it goes direct. The key is held
/// only for the run that resolved it.
nonisolated struct AnalysisRouteResolution: Sendable {
    let feature: AnalysisFeature
    let route: AnalysisRoute
    /// `nil` only for `keyRequired`.
    let policy: AnalysisRoutePolicy?
    /// The listener's key; set only for `direct`.
    let key: AnalysisProviderKey?
    /// The run being resumed, when the route was resolved for one.
    let resumingRunID: String?
    /// The trial service exchange; set only for `trial`.
    let trialExchange: (any AnalysisTrialProxyExchange)?

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
