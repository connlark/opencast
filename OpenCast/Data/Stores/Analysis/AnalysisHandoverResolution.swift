/// Whether a run on a key Google named free tier can move to the trial
/// service. Cancellation is the caller's to check; it is never one of these.
nonisolated enum AnalysisHandoverResolution: Sendable {
    /// The trial policy exists, the exchange connects and the service says
    /// it is open.
    case available(AnalysisRouteResolution)
    /// The trial date has passed, or the service says the trial has begun.
    case notOpen
    /// The service is out of reach: not reachable from this build and device,
    /// no exchange, or a status that could not be read.
    case unavailable
}
