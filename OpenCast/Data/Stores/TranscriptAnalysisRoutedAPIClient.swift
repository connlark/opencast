import Foundation

/// Release-only lane router for draining Chapters & Summary jobs the service
/// accepted before the update. It resolves the StoreKit
/// environment once, then pins every request for this process to one
/// concrete client — sandbox/TestFlight installs must exercise prod-staging
/// billing, production installs the production lane. An unknown or failed
/// environment lookup never falls back to a money/state lane; requests fail
/// with the quiet `clientDisabled` error until resolution succeeds.
actor TranscriptAnalysisRoutedAPIClient: EpisodeTranscriptAnalysisClient {
    private let environmentProvider: @Sendable () async throws -> RemoteTranscriptionStoreEnvironment
    private let clientFactory: @Sendable (
        TranscriptAnalysisBackendConfiguration
    ) -> any EpisodeTranscriptAnalysisClient
    private var resolvedClient: (any EpisodeTranscriptAnalysisClient)?

    init(
        environmentProvider: @escaping @Sendable () async throws -> RemoteTranscriptionStoreEnvironment =
            RemoteTranscriptionAppTransactionProvider.currentEnvironment,
        clientFactory: @escaping @Sendable (
            TranscriptAnalysisBackendConfiguration
        ) -> any EpisodeTranscriptAnalysisClient = { configuration in
            URLSessionEpisodeTranscriptAnalysisClient(configuration: configuration)
        }
    ) {
        self.environmentProvider = environmentProvider
        self.clientFactory = clientFactory
    }

    func pollJob(id: String) async throws -> EpisodeTranscriptAnalysisJobPollOutcome {
        try await client().pollJob(id: id)
    }

    private func client() async throws -> any EpisodeTranscriptAnalysisClient {
        if let resolvedClient {
            return resolvedClient
        }

        let environment = (try? await environmentProvider()) ?? .unknown("unavailable")
        let configuration = TranscriptAnalysisBackendConfiguration.release(for: environment)
        guard configuration.isEnabled else {
            throw EpisodeTranscriptAnalysisError.clientDisabled
        }
        let client = clientFactory(configuration)
        resolvedClient = client
        return client
    }
}
