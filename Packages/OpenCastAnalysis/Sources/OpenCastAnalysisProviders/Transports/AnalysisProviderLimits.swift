import OpenCastAnalysis

extension AnalysisBilledUsage {
    public static func billed(provider: AnalysisProvider, body: String) -> AnalysisBilledUsage? {
        switch provider {
        case .google: GeminiAnalysisTransport.interpret(body).usage
        case .openai: OpenAIResponsesMapping.answer(fromBody: body).usage
        }
    }
}

public enum AnalysisProviderLimits {
    /// Matches the analysis services' cap on a Gemini reply.
    public static let maxResponseBytes = 512 * 1024
    public static let auxiliaryCallTimeoutSeconds = 30.0
    /// A day: far past every run budget, and small enough for every clock and `Duration`.
    public static let maximumWaitSeconds = 86_400.0

    /// NaN and negative values are no wait; infinity clamps to ``maximumWaitSeconds``.
    public static func waitSeconds(_ seconds: Double) -> Double {
        guard seconds > 0 else { return 0 }
        return min(seconds, maximumWaitSeconds)
    }
}
