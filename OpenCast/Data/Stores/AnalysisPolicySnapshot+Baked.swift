import OpenCastAnalysis

nonisolated extension AnalysisPolicySnapshot {
    /// The bundle this build ships with, before any download is consulted.
    static var baked: AnalysisPolicySnapshot {
        AnalysisPolicySnapshot(bundle: .baked, source: .baked, fallbackReason: nil, lastRefreshFailure: nil)
    }

    /// The model `feature` runs on with `provider`'s key, or `nil` when the
    /// bundle offers the provider nothing for that feature.
    func modelEntry(for feature: AnalysisFeature, provider: AnalysisProvider) -> AnalysisModelEntry? {
        switch feature {
        case .adDetection:
            adDetection(provider: provider)?.model
        case .chaptersSummary:
            chaptersSummary(provider: provider)?.model
        }
    }
}
