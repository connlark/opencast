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

    @Test func failedLookupRetriesWithoutRelaunchAndPinsSubmitPollAndRevision() async throws {
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
        await #expect(throws: URLError.self) { _ = try await router.analyze(Self.request) }
        _ = try await router.analyze(Self.request)
        _ = try await router.pollJob(id: "a3.20260911b.fingerprint123")
        #expect(try await router.servingPolicyRevision() == "revision")
        #expect(state.lookups.withLock { $0 } == 2)
        #expect(state.configurations.withLock { $0 }.map(\.workerBaseURL) == [AdAnalysisBackendConfiguration.prodStaging.workerBaseURL])
        #expect(await stub.events == ["submit", "poll:a3.20260911b.fingerprint123", "revision"])
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

    @Test func acceptedHandlesValidateInputAndSurviveLocalPersistence() throws {
        let fingerprint = "fingerprint123"
        for handle in [fingerprint, "a3.20260911a.\(fingerprint)", "a3.20260911b.\(fingerprint)"] {
            #expect(EpisodeAdAnalysisJobHandle.matches(handle, fingerprint: fingerprint))
        }
        #expect(EpisodeAdAnalysisJobHandle.sameInput("a3.20260911a.\(fingerprint)", "a3.20260911b.\(fingerprint)"))
        for handle in ["a3../arbitrary", "a3..\(fingerprint)", "a3.valid.otherfingerprint", "a3." + String(repeating: "x", count: 1000)] {
            #expect(!EpisodeAdAnalysisJobHandle.matches(handle, fingerprint: fingerprint))
        }
        let files = EpisodeAdAnalysisFileStore(baseDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let state = EpisodeAdAnalysisRunState(transcriptFingerprint: fingerprint, jobID: "a3.20260911a.\(fingerprint)")
        try files.writeRunState(state, episodeID: "episode")
        #expect(try files.readRunState(episodeID: "episode") == state)
        try files.deleteAllAnalyses()
    }

    nonisolated private static let request = EpisodeAdAnalysisAPIRequest(
        schemaVersion: 1, requestID: "request", episodeID: "episode", podcastID: "podcast",
        transcript: .init(languageCode: "en", audioDuration: 10, fingerprint: "fingerprint123", updatedAt: .distantPast, state: "completed", segmentCount: 1),
        segments: [.init(id: 0, start: 0, end: 10, text: "Hello")])
}

private final class RoutingState: Sendable {
    let lookups = Mutex(0)
    let configurations = Mutex<[AdAnalysisBackendConfiguration]>([])
}

private actor RoutingClient: EpisodeAdAnalysisClient {
    private(set) var events: [String] = []
    func analyze(_ request: EpisodeAdAnalysisAPIRequest) async throws -> EpisodeAdAnalysisSubmitOutcome {
        events.append("submit")
        return .accepted(jobID: "a3.20260911b.\(request.transcript.fingerprint)", pollAfter: 1)
    }
    func pollJob(id: String) async throws -> EpisodeAdAnalysisJobPollOutcome {
        events.append("poll:\(id)")
        return .running(pollAfter: 1)
    }
    func servingPolicyRevision() async throws -> String? { events.append("revision"); return "revision" }
}
