/// Whether a run on a free-tier key can move to the trial service. Cancellation is the caller's
/// to check.
nonisolated enum AnalysisHandoverResolution: Sendable {
    case available(AnalysisRouteResolution)
    case notOpen
    case unavailable
}
