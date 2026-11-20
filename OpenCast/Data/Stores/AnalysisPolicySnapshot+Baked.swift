import OpenCastAnalysis

nonisolated extension AnalysisPolicySnapshot {
    static var baked: AnalysisPolicySnapshot {
        AnalysisPolicySnapshot(bundle: .baked, source: .baked, fallbackReason: nil, lastRefreshFailure: nil)
    }

    func modelEntry(for feature: AnalysisFeature, provider: AnalysisProvider) -> AnalysisModelEntry? {
        switch feature {
        case .adDetection:
            adDetection(provider: provider)?.model
        case .chaptersSummary:
            chaptersSummary(provider: provider)?.model
        }
    }
}
