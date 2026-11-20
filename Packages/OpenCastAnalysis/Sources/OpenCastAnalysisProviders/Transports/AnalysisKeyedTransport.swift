import OpenCastAnalysis

public struct AnalysisTokenCount: Sendable, Hashable {
    public var tokens: Int
    public var isEstimated: Bool

    public init(tokens: Int, isEstimated: Bool) {
        self.tokens = tokens
        self.isEstimated = isEstimated
    }

    /// The fallback for a body of `bytes` UTF-8 bytes.
    public static func estimate(bytes: Int) -> AnalysisTokenCount {
        AnalysisTokenCount(tokens: (bytes + 2) / 3, isEstimated: true)
    }
}

public enum AnalysisKeyTestResult: Sendable, Hashable {
    case accepted
    case failed(AnalysisProviderFailure)
}

public protocol AnalysisKeyedTransport: AnalysisProviderTransport {
    var provider: AnalysisProvider { get }
    /// A failed count falls back to ``AnalysisTokenCount/estimate(bytes:)``.
    func countTokens(
        feature: AnalysisFeature,
        model: AnalysisModelEntry,
        payload: JSONValue,
        thinking: String?
    ) async -> AnalysisTokenCount
    /// The cheapest authenticated call: Gemini `countTokens` on the entry's model, OpenAI
    /// `GET /models`.
    func testKey(model: AnalysisModelEntry) async -> AnalysisKeyTestResult
}

extension AnalysisKeyedTransport {
    public func countTokens(_ request: AnalysisProviderRequest) async -> AnalysisTokenCount {
        await countTokens(feature: request.feature, model: request.model, payload: request.payload, thinking: request.thinking)
    }
}

public enum AnalysisProviderConfigurationError: Error, Sendable, Hashable {
    /// Not `https` on the provider's pinned host, or unsafe paths.
    case unpinnedEndpoint
    case wrongAuthentication
}
