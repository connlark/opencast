import OpenCastAnalysis

extension AnalysisBilledUsage {
    /// The usage a provider billed, read from its raw 2xx body exactly as the
    /// transports read it; `nil` when the body reports none. Numbers only.
    public static func billed(provider: AnalysisProvider, body: String) -> AnalysisBilledUsage? {
        switch provider {
        case .google: GeminiAnalysisTransport.interpret(body).usage
        case .openai: OpenAIResponsesMapping.answer(fromBody: body).usage
        }
    }
}

/// Bounds every provider transport applies.
public enum AnalysisProviderLimits {
    /// Largest provider body read, in bytes: the analysis services' cap on a
    /// Gemini reply. A longer body fails as ``AnalysisTransportError/oversizedBody``.
    public static let maxResponseBytes = 512 * 1024
    /// Deadline for a token count or a key test, which run outside any
    /// analysis run.
    public static let auxiliaryCallTimeoutSeconds = 30.0
    /// The longest wait any timeout here turns into: a day, far past every
    /// run budget, and small enough for every clock and `Duration`.
    public static let maximumWaitSeconds = 86_400.0

    /// `seconds` as a wait: NaN and negative values are no time at all,
    /// anything longer (infinity included) is ``maximumWaitSeconds``.
    public static func waitSeconds(_ seconds: Double) -> Double {
        guard seconds > 0 else { return 0 }
        return min(seconds, maximumWaitSeconds)
    }
}
