import OpenCastAnalysis
import OpenCastAnalysisProviders

/// A test outcome never changes stored state.
nonisolated protocol AnalysisKeyTesting: Sendable {
    func test(_ key: AnalysisProviderKey, provider: AnalysisProvider, snapshot: AnalysisPolicySnapshot) async -> AnalysisKeyTestResult

    /// `test` cannot tell the tier: `countTokens` is not a model request.
    func checkTier(_ key: AnalysisProviderKey, snapshot: AnalysisPolicySnapshot) async -> AnalysisTierCheckResult
}
