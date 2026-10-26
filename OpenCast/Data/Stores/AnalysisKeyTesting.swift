import OpenCastAnalysis
import OpenCastAnalysisProviders

/// Checks a key with its provider's cheapest authenticated call, without
/// running an analysis. A test outcome never changes stored state.
nonisolated protocol AnalysisKeyTesting: Sendable {
    func test(_ key: AnalysisProviderKey, provider: AnalysisProvider, snapshot: AnalysisPolicySnapshot) async -> AnalysisKeyTestResult
}
