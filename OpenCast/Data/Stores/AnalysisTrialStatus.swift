/// Where this install stands in the opencast-funded trial, as last reported
/// by the trial service.
nonisolated enum AnalysisTrialStatus: Hashable, Sendable {
    case notStarted
    case unitsLeft(Int)
    case exhausted
}
