import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Transcript analysis lane router")
struct TranscriptAnalysisRoutedAPIClientTests {
    @Test("Release lanes map StoreKit environments; unknown fails closed")
    func releaseLaneMapping() {
        let production = TranscriptAnalysisBackendConfiguration.release(for: .production)
        #expect(production.isEnabled)
        #expect(production.workerBaseURL == TranscriptAnalysisBackendConfiguration.production.workerBaseURL)

        for environment in [RemoteTranscriptionStoreEnvironment.sandbox, .xcode] {
            let configuration = TranscriptAnalysisBackendConfiguration.release(for: environment)
            #expect(configuration.isEnabled)
            #expect(
                configuration.workerBaseURL
                    == TranscriptAnalysisBackendConfiguration.prodStaging.workerBaseURL
            )
        }

        #expect(!TranscriptAnalysisBackendConfiguration.release(for: .unknown("unavailable")).isEnabled)
    }

    @Test("Router resolves the environment once and pins every call to one client")
    func routerResolvesOnceAndPins() async throws {
        let stub = RoutedStubEpisodeTranscriptAnalysisClient()
        let environmentCalls = CountingBox()
        let factoryConfigurations = ConfigurationBox()
        let router = TranscriptAnalysisRoutedAPIClient(
            environmentProvider: {
                await environmentCalls.increment()
                return .sandbox
            },
            clientFactory: { configuration in
                factoryConfigurations.append(configuration)
                return stub
            }
        )

        _ = try await router.analyze(RoutedStubEpisodeTranscriptAnalysisClient.request)
        _ = try await router.pollJob(id: "job")
        try await router.bootstrapAccount()

        #expect(await environmentCalls.value == 1)
        #expect(factoryConfigurations.configurations.count == 1)
        #expect(
            factoryConfigurations.configurations.first?.workerBaseURL
                == TranscriptAnalysisBackendConfiguration.prodStaging.workerBaseURL
        )
        #expect(stub.events == ["analyze", "poll", "bootstrap"])
    }

    @Test("Unresolvable environment fails closed without constructing a client")
    func unresolvableEnvironmentFailsClosed() async {
        let factoryConfigurations = ConfigurationBox()
        let router = TranscriptAnalysisRoutedAPIClient(
            environmentProvider: { throw CancellationError() },
            clientFactory: { configuration in
                factoryConfigurations.append(configuration)
                return RoutedStubEpisodeTranscriptAnalysisClient()
            }
        )

        await #expect(throws: EpisodeTranscriptAnalysisError.clientDisabled) {
            _ = try await router.analyze(RoutedStubEpisodeTranscriptAnalysisClient.request)
        }
        #expect(factoryConfigurations.configurations.isEmpty)
    }
}

private actor CountingBox {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

/// Factory calls arrive from the router actor; the lock keeps the recorder
/// Sendable without forcing the factory closure onto an actor.
private final class ConfigurationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TranscriptAnalysisBackendConfiguration] = []

    var configurations: [TranscriptAnalysisBackendConfiguration] {
        lock.withLock { storage }
    }

    func append(_ configuration: TranscriptAnalysisBackendConfiguration) {
        lock.withLock { storage.append(configuration) }
    }
}

private final class RoutedStubEpisodeTranscriptAnalysisClient: EpisodeTranscriptAnalysisClient, @unchecked Sendable {
    static let request = EpisodeTranscriptAnalysisAPIRequest(
        schemaVersion: 1,
        requestID: "routed-request",
        episodeID: "routed-episode",
        podcastID: "https://example.com/routed.xml",
        episodeTitle: "Episode",
        podcastTitle: "Podcast",
        asyncSupported: true,
        allowShared: false,
        transcript: EpisodeTranscriptAnalysisAPITranscriptMetadata(
            languageCode: "en",
            audioDuration: 10,
            modelIdentifier: "model",
            modelVersion: "v1",
            modelTreeSHA256: "tree",
            fingerprint: "routed-fingerprint",
            updatedAt: Date(timeIntervalSince1970: 1_780_000_000),
            state: "completed",
            segmentCount: 1
        ),
        segments: [
            EpisodeTranscriptAnalysisAPISegment(id: 0, start: 0, end: 10, text: "Hello.")
        ]
    )

    private(set) var events: [String] = []

    func analyze(_ request: EpisodeTranscriptAnalysisAPIRequest) async throws -> EpisodeTranscriptAnalysisSubmitOutcome {
        events.append("analyze")
        return .accepted(jobID: request.transcript.fingerprint, pollAfter: 1)
    }

    func pollJob(id: String) async throws -> EpisodeTranscriptAnalysisJobPollOutcome {
        events.append("poll")
        return .running(pollAfter: 1)
    }

    func bootstrapAccount() async throws {
        events.append("bootstrap")
    }
}
