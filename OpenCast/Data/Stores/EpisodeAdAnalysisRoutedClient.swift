import Foundation

/// Pin submits and subsequent polls to the same StoreKit environment as the
/// cloud transcription path. Unknown environments never guess production.
actor EpisodeAdAnalysisRoutedClient: EpisodeAdAnalysisClient {
    private let environmentProvider: @Sendable () async throws -> RemoteTranscriptionStoreEnvironment
    private let clientFactory: @Sendable (AdAnalysisBackendConfiguration) -> any EpisodeAdAnalysisClient
    private var resolvedClient: (any EpisodeAdAnalysisClient)?

    init(
        environmentProvider: @escaping @Sendable () async throws -> RemoteTranscriptionStoreEnvironment =
            RemoteTranscriptionAppTransactionProvider.currentEnvironment,
        clientFactory: @escaping @Sendable (AdAnalysisBackendConfiguration) -> any EpisodeAdAnalysisClient = {
            URLSessionEpisodeAdAnalysisClient(configuration: $0)
        }
    ) {
        self.environmentProvider = environmentProvider
        self.clientFactory = clientFactory
    }

    func analyze(_ request: EpisodeAdAnalysisAPIRequest) async throws -> EpisodeAdAnalysisSubmitOutcome {
        try await client().analyze(request)
    }

    func pollJob(id: String) async throws -> EpisodeAdAnalysisJobPollOutcome {
        try await client().pollJob(id: id)
    }

    func servingPolicyRevision() async throws -> String? {
        try await client().servingPolicyRevision()
    }

    private func client() async throws -> any EpisodeAdAnalysisClient {
        if let resolvedClient { return resolvedClient }
        let environment = try await environmentProvider()
        try Task.checkCancellation()
        if let resolvedClient { return resolvedClient }
        guard let configuration = AdAnalysisBackendConfiguration.release(for: environment) else {
            throw EpisodeAdAnalysisError.clientDisabled
        }
        let client = clientFactory(configuration)
        resolvedClient = client
        return client
    }
}
