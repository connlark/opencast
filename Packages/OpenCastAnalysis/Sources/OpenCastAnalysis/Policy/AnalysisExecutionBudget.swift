/// How an ad-detection run spends its time on the device. Chosen by the
/// route in memory: no bundle carries it and no run record keeps it.
/// Chapters & Summary ignores it.
public enum AnalysisExecutionBudget: Sendable, Hashable {
    /// The ad-analysis service's allocation: the model's run budget shared
    /// across the worst-case waves of windows.
    case service
    /// The trial's serial allocation: ``AdTrialRunConstants/runBudgetSeconds``
    /// for the run, each send up to the model's per-call timeout while at
    /// least ``AdTrialRunConstants/sendFloorSeconds`` remain.
    case trial
}
