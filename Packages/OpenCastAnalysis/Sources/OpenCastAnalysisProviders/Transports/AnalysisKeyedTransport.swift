import OpenCastAnalysis

/// A token count for a request, exact when the provider counted it.
public struct AnalysisTokenCount: Sendable, Hashable {
    public var tokens: Int
    /// `true` when the count call failed and `tokens` is the request body's
    /// UTF-8 size divided by three, rounded up (the run is then marked
    /// `input_estimated`).
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

/// The result of the cheapest authenticated call a provider offers.
public enum AnalysisKeyTestResult: Sendable, Hashable {
    case accepted
    case failed(AnalysisProviderFailure)
}

/// A transport that calls one provider directly with the listener's key.
/// Besides sending pipeline requests it can count a request's input tokens
/// (for the pre-run estimate) and test the key.
public protocol AnalysisKeyedTransport: AnalysisProviderTransport {
    var provider: AnalysisProvider { get }
    /// The input tokens of one canonical payload (as the pipeline would send
    /// it for `feature` on `model` at `thinking`), for the pre-run estimate.
    /// Never throws: a failed count falls back to an estimate.
    func countTokens(
        feature: AnalysisFeature,
        model: AnalysisModelEntry,
        payload: JSONValue,
        thinking: String?
    ) async -> AnalysisTokenCount
    /// Gemini: `countTokens` on the entry's model. OpenAI: `GET /models`.
    func testKey(model: AnalysisModelEntry) async -> AnalysisKeyTestResult
}

extension AnalysisKeyedTransport {
    /// The input tokens of a pipeline request.
    public func countTokens(_ request: AnalysisProviderRequest) async -> AnalysisTokenCount {
        await countTokens(feature: request.feature, model: request.model, payload: request.payload, thinking: request.thinking)
    }
}

/// Why a transport could not be built.
public enum AnalysisProviderConfigurationError: Error, Sendable, Hashable {
    /// The endpoint is not `https` on the provider's pinned host, or its
    /// paths are unsafe.
    case unpinnedEndpoint
    /// The endpoint's authentication style is not the provider's.
    case wrongAuthentication
}
