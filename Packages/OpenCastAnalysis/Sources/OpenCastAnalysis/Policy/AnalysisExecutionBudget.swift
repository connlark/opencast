/// In memory only: no bundle carries it and no run record keeps it.
public enum AnalysisExecutionBudget: Sendable, Hashable {
    case service
    case trial
}
