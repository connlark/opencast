import OpenCastAnalysis
import OpenCastAnalysisProviders

/// Tests a key through the provider's own transport: Gemini `countTokens` on
/// the bundle's model, OpenAI `GET /models`. The call is an unpaced auxiliary
/// call; the transport registers the key with the logger itself.
nonisolated struct AnalysisProviderKeyTester: AnalysisKeyTesting {
    private let client: any AnalysisHTTPClient
    private let logger: RedactingLogger

    init(
        client: any AnalysisHTTPClient = URLSessionAnalysisHTTPClient(),
        logger: RedactingLogger = RedactingLogger(category: "AnalysisKeyTest")
    ) {
        self.client = client
        self.logger = logger
    }

    /// No endpoint or model for the provider is `model_unavailable`; an
    /// endpoint the transport refuses is `request_rejected`.
    func test(_ key: AnalysisProviderKey, provider: AnalysisProvider, snapshot: AnalysisPolicySnapshot) async -> AnalysisKeyTestResult {
        guard let endpoint = snapshot.bundle.providers[provider],
              let model = snapshot.adDetection(provider: provider)?.model
                ?? snapshot.chaptersSummary(provider: provider)?.model
        else {
            return .failed(.modelUnavailable)
        }
        let transport: any AnalysisKeyedTransport
        do {
            transport = try makeTransport(provider: provider, endpoint: endpoint, key: key)
        } catch {
            return .failed(.requestRejected)
        }
        return await transport.testKey(model: model)
    }

    private func makeTransport(
        provider: AnalysisProvider,
        endpoint: AnalysisProviderEndpoint,
        key: AnalysisProviderKey
    ) throws(AnalysisProviderConfigurationError) -> any AnalysisKeyedTransport {
        switch provider {
        case .google:
            return try GeminiAnalysisTransport(endpoint: endpoint, key: key, client: client, pacer: nil, logger: logger)
        case .openai:
            return try OpenAIAnalysisTransport(endpoint: endpoint, key: key, client: client, pacer: nil, logger: logger)
        }
    }
}
