import Foundation
import Synchronization
import Testing
@testable import OpenCast

@MainActor
@Suite("Ad analysis Release routing and accepted handles")
struct EpisodeAdAnalysisRoutedClientTests {
    @Test func releaseMatrixAndRegistrationIdentities() throws {
        #expect(AdAnalysisBackendConfiguration.release(for: .production)?.workerBaseURL == AdAnalysisBackendConfiguration.production.workerBaseURL)
        for environment in [RemoteTranscriptionStoreEnvironment.sandbox, .xcode] {
            #expect(AdAnalysisBackendConfiguration.release(for: environment)?.workerBaseURL == AdAnalysisBackendConfiguration.prodStaging.workerBaseURL)
        }
        #expect(AdAnalysisBackendConfiguration.release(for: .unknown("future")) == nil)
        #expect(AdAnalysisAppAttestKeychainServices.prodStaging != AdAnalysisAppAttestKeychainServices.production)
        #expect(AdAnalysisAppAttestKeychainServices.prodStaging != AdAnalysisAppAttestKeychainServices.development)
    }

    @Test func failedLookupRetriesWithoutRelaunchAndPinsPolls() async throws {
        let state = RoutingState()
        let stub = RoutingClient()
        let router = EpisodeAdAnalysisRoutedClient(environmentProvider: {
            let count = state.lookups.withLock { $0 += 1; return $0 }
            if count == 1 { throw URLError(.notConnectedToInternet) }
            return .sandbox
        }, clientFactory: { config in
            state.configurations.withLock { $0.append(config) }
            return stub
        })
        await #expect(throws: URLError.self) { _ = try await router.pollJob(id: "a3.20260911b.fingerprint123") }
        _ = try await router.pollJob(id: "a3.20260911b.fingerprint123")
        _ = try await router.pollJob(id: "fingerprint123")
        #expect(state.lookups.withLock { $0 } == 2)
        #expect(state.configurations.withLock { $0 }.map(\.workerBaseURL) == [AdAnalysisBackendConfiguration.prodStaging.workerBaseURL])
        #expect(await stub.events == ["poll:a3.20260911b.fingerprint123", "poll:fingerprint123"])
    }

    @Test func concurrentResolutionConstructsOneSelectedClient() async throws {
        let state = RoutingState()
        let stub = RoutingClient()
        let router = EpisodeAdAnalysisRoutedClient(environmentProvider: {
            await Task.yield()
            return .sandbox
        }, clientFactory: { config in
            state.configurations.withLock { $0.append(config) }
            return stub
        })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { _ = try await router.pollJob(id: "fingerprint123") } }
            try await group.waitForAll()
        }
        #expect(state.configurations.withLock { $0.count } == 1)
        #expect(await stub.events.count == 8)
    }
}

private final class RoutingState: Sendable {
    let lookups = Mutex(0)
    let configurations = Mutex<[AdAnalysisBackendConfiguration]>([])
}

private actor RoutingClient: EpisodeAdAnalysisClient {
    private(set) var events: [String] = []
    func pollJob(id: String) async throws -> EpisodeAdAnalysisJobPollOutcome {
        events.append("poll:\(id)")
        return .running(pollAfter: 1)
    }
}
