import OpenCastAnalysis

/// How one analysis run reaches a model.
nonisolated enum AnalysisRoute: Sendable, Hashable {
    /// The listener's own key, straight to the provider.
    case direct(provider: AnalysisProvider)
    /// The opencast-funded trial service, which adds opencast's Gemini key.
    case trial
    /// Neither: the feature shows the key screen.
    case keyRequired(AnalysisKeyRequiredReason)
}
