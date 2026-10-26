import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import OpenCastTranscription
import SwiftData
import Synchronization
import Testing
@testable import OpenCast

/// Ad detection end to end on the direct route with a real key: the store,
/// the route resolver, the transport factory and the provider, on the
/// synthetic carousel transcript. Each test runs only where the environment
/// names a readable key file (`TEST_RUNNER_<name>` on xcodebuild); the key
/// is read by path into in-memory key storage, never the Keychain, and
/// never printed. When `OPENCAST_ANALYSIS_LIVE_OUTPUT_DIR` names a
/// directory, each test writes the run's billed usage there (numbers only).
@MainActor
@Suite("Ad detection live direct route")
struct AdDetectionLiveRouteTests {
    @Test("A Google key detects the carousel's breaks on the device and the zones map", .enabled(if: LiveRouteKeyFile.path(for: .google) != nil))
    func googleDirectRun() async throws {
        try await liveRun(provider: .google)
    }

    @Test("An OpenAI key detects the carousel's breaks on the device and the zones map", .enabled(if: LiveRouteKeyFile.path(for: .openai) != nil))
    func openAIDirectRun() async throws {
        try await liveRun(provider: .openai)
    }

    private func liveRun(provider: AnalysisProvider) async throws {
        guard let path = LiveRouteKeyFile.path(for: provider),
              let key = AnalysisProviderKey(try String(contentsOfFile: path, encoding: .utf8))
        else {
            Issue.record("No key file for \(provider.rawValue)")
            return
        }
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let root = FileManager.default.temporaryDirectory.appending(path: "AdDetectionLive-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let keys = AnalysisProviderKeyStore(storage: InMemoryAnalysisProviderKeyStorage(seeded: [provider: (key, syncs: false)]))
        let policy = AnalysisPolicySnapshotStore.fixed(.baked)
        let runs = AnalysisRunRecordStore(directory: root.appending(path: "AnalysisRuns", directoryHint: .isDirectory))
        let trialStatus = AnalysisTrialStatusCache(defaults: UserDefaults(suiteName: "opencast.live-route.\(UUID().uuidString)")!) { nil }
        let client = UsageRecordingHTTPClient(provider: provider)
        let environment = EpisodeAdAnalysisLiveRunEnvironment(
            routes: AnalysisRouteResolver(
                keys: keys,
                policy: policy,
                storedProvider: { _ in provider },
                trialStatus: trialStatus,
                trial: NoTrialConnection(),
                runs: runs
            ),
            transports: AnalysisTransportFactory(policy: policy, runs: runs, keys: keys.storage, client: client),
            runs: runs,
            usage: AnalysisUsageStore(),
            trialStatus: trialStatus,
            policy: policy,
            presentKeyRequired: { _ in },
            holdsContinuedProcessingCard: { false }
        )
        let store = EpisodeAdAnalysisStore(
            client: UnpolledAdAnalysisClient(),
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: root),
            runEnvironment: environment
        )
        let transcript = try Self.carouselTranscript()

        store.startAnalysis(transcript: transcript, modelContext: context)
        let deadline = ContinuousClock.now + .seconds(600)
        while store.hasActiveJob || store.record(for: transcript.episodeID)?.state == .running {
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: .milliseconds(200))
        }

        let record = try #require(store.record(for: transcript.episodeID))
        let run = try #require(runs.records(limit: 1).first)
        try Self.writeOutput(provider: provider, run: run, usage: client.usages, record: record)
        #expect(record.state == .completed)
        #expect(run.route == .direct)
        #expect(run.provider == provider)
        #expect(run.state == .finished)
        let document = try #require(store.document(for: transcript.episodeID))
        #expect(EpisodeAdAnalysisContract.supports(policy: document.policy))
        #expect(!document.spans.isEmpty)
        #expect(!EpisodeAdAnalysisZoneMapper.zones(for: document, duration: transcript.audioDuration).isEmpty)
    }

    /// The synthetic carousel (the only corpus allowed in tests) as a
    /// completed transcript.
    static func carouselTranscript() throws -> EpisodeTranscriptDocument {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Server/AdAnalysisWorker/eval/fixtures/promo-carousel.json")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let rows = try #require(object["segments"] as? [[String: Any]])
        let segments = try rows.map { row in
            OpenCastTranscriptSegment(
                id: try #require(row["id"] as? Int),
                start: try #require((row["start"] as? NSNumber)?.doubleValue),
                end: try #require((row["end"] as? NSNumber)?.doubleValue),
                text: try #require(row["text"] as? String),
                avgLogProbability: -0.1,
                noSpeechProbability: 0.01
            )
        }
        let updatedAt = Date(timeIntervalSince1970: 1_792_000_000)
        return EpisodeTranscriptDocument(
            schemaVersion: 1,
            episodeID: "live-route-carousel",
            podcastID: "live-route-podcast",
            sourceAudioURL: "https://example.com/live-route-carousel.mp3",
            sourceFileByteCount: 1,
            sourceFileSHA256: "live-route",
            modelIdentifier: "model",
            modelVersion: "v1",
            modelTreeSHA256: "tree",
            languageCode: "en",
            audioDuration: 800,
            checkpoints: [],
            segments: segments,
            text: segments.map(\.text).joined(separator: " "),
            timings: EpisodeTranscriptTimings(),
            createdAt: updatedAt.addingTimeInterval(-10),
            updatedAt: updatedAt
        )
    }

    private static func writeOutput(
        provider: AnalysisProvider,
        run: AnalysisRunRecord,
        usage: [AnalysisBilledUsage],
        record: EpisodeAdAnalysisRecord
    ) throws {
        guard let directory = ProcessInfo.processInfo.environment["OPENCAST_ANALYSIS_LIVE_OUTPUT_DIR"] else { return }
        let output: [String: Any] = [
            "provider": provider.rawValue,
            "model": run.modelID,
            "run_state": run.state.rawValue,
            "outcome_code": run.outcomeCode ?? "",
            "record_state": record.state.rawValue,
            "span_count": record.spanCount,
            "run_input_tokens": run.inputTokens,
            "run_output_tokens": run.outputTokens,
            "calls": usage.map { ["input": $0.input, "cached": $0.cached, "write": $0.write, "output": $0.output, "reasoning": $0.reasoning] },
        ]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: URL(fileURLWithPath: directory).appending(path: "live-direct-\(provider.rawValue).json"))
    }
}

private enum LiveRouteKeyFile {
    static func path(for provider: AnalysisProvider) -> String? {
        let variable = switch provider {
        case .google: "OPENCAST_ANALYSIS_LIVE_GOOGLE_KEY_FILE"
        case .openai: "OPENCAST_ANALYSIS_LIVE_OPENAI_KEY_FILE"
        }
        guard let path = ProcessInfo.processInfo.environment[variable],
              FileManager.default.isReadableFile(atPath: path)
        else {
            return nil
        }
        return path
    }
}

/// No trial route: the live runs can only go direct.
private struct NoTrialConnection: AnalysisTrialConnecting {
    var isConfigured: Bool { false }

    func exchange(trialEndpoint: URL) async -> (any AnalysisTrialProxyExchange)? {
        nil
    }
}

/// The real HTTP client, keeping each 2xx reply's billed usage (numbers
/// only) for the spend ledger.
private final class UsageRecordingHTTPClient: AnalysisHTTPClient {
    let provider: AnalysisProvider
    private let inner = URLSessionAnalysisHTTPClient()
    private let recorded = Mutex<[AnalysisBilledUsage]>([])

    init(provider: AnalysisProvider) {
        self.provider = provider
    }

    var usages: [AnalysisBilledUsage] { recorded.withLock { $0 } }

    func send(
        _ request: AnalysisHTTPRequest,
        timeoutSeconds: Double,
        maximumBodyBytes: Int
    ) async throws(AnalysisHTTPFailure) -> AnalysisHTTPResponse {
        let response = try await inner.send(request, timeoutSeconds: timeoutSeconds, maximumBodyBytes: maximumBodyBytes)
        if (200..<300).contains(response.status),
           let body = String(validating: response.body, as: UTF8.self),
           let usage = AnalysisBilledUsage.billed(provider: provider, body: body) {
            recorded.withLock { $0.append(usage) }
        }
        return response
    }
}
