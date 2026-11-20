import OpenCastAnalysis
import OpenCastAnalysisProviders

/// The transport registers the key with the redacting logger itself.
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

    func checkTier(_ key: AnalysisProviderKey, snapshot: AnalysisPolicySnapshot) async -> AnalysisTierCheckResult {
        guard let endpoint = snapshot.bundle.providers[.google],
              let transport = try? GeminiAnalysisTransport(endpoint: endpoint, key: key, client: client, pacer: nil, logger: logger)
        else {
            return .inconclusive
        }
        return await transport.checkTier()
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
