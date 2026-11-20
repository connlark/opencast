import OpenCastAnalysis

nonisolated enum AnalysisRoute: Sendable, Hashable {
    case direct(provider: AnalysisProvider)
    case trial
    case keyRequired(AnalysisKeyRequiredReason)
}
