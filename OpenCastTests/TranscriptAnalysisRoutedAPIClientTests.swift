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

        _ = try await router.pollJob(id: "job")
        _ = try await router.pollJob(id: "job")

        #expect(await environmentCalls.value == 1)
        #expect(factoryConfigurations.configurations.count == 1)
        #expect(
            factoryConfigurations.configurations.first?.workerBaseURL
                == TranscriptAnalysisBackendConfiguration.prodStaging.workerBaseURL
        )
        #expect(stub.events == ["poll", "poll"])
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
            _ = try await router.pollJob(id: "job")
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
    private(set) var events: [String] = []

    func pollJob(id: String) async throws -> EpisodeTranscriptAnalysisJobPollOutcome {
        events.append("poll")
        return .running(pollAfter: 1)
    }
}
