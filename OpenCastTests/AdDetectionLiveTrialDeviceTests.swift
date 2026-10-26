import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import OpenCastTranscription
import SwiftData
import Synchronization
import Testing
@testable import OpenCast

/// Ad detection through the trial service on a physical device: App Attest
/// registration with the build's trial lane, the attested status read and
/// one trial-route run of the synthetic carousel (embedded, since a device
/// cannot read the repository). Runs only where
/// `OPENCAST_ANALYSIS_LIVE_TRIAL_DEVICE=1` and the device can attest. Its
/// evidence, ids and numbers only, is attached to the result.
@MainActor
@Suite("Ad detection live trial route on a device")
struct AdDetectionLiveTrialDeviceTests {
    nonisolated static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["OPENCAST_ANALYSIS_LIVE_TRIAL_DEVICE"] == "1"
            && AnalysisTrialConnection().isConfigured
    }

    @Test("A device with no key registers, reads its trial status and detects the carousel's breaks through the trial", .enabled(if: isEnabled))
    func trialRunOnDevice() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let root = FileManager.default.temporaryDirectory.appending(path: "AdDetectionLiveTrial-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let connection = RecordingTrialConnection(inner: AnalysisTrialConnection())
        let policy = AnalysisPolicySnapshotStore.fixed(.baked)
        let trialEndpoint = policy.snapshot.bundle.trial.endpoint
        let status = await connection.inner.fetchStatus(trialEndpoint: trialEndpoint)
        let runs = AnalysisRunRecordStore(directory: root.appending(path: "AnalysisRuns", directoryHint: .isDirectory))
        let trialStatus = AnalysisTrialStatusCache(defaults: UserDefaults(suiteName: "opencast.live-trial.\(UUID().uuidString)")!) { status }
        let keys = AnalysisProviderKeyStore(storage: InMemoryAnalysisProviderKeyStorage())
        let environment = EpisodeAdAnalysisLiveRunEnvironment(
            routes: AnalysisRouteResolver(
                keys: keys,
                policy: policy,
                storedProvider: { _ in nil },
                trialStatus: trialStatus,
                trial: connection,
                runs: runs
            ),
            transports: AnalysisTransportFactory(policy: policy, runs: runs, keys: keys.storage),
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
        let transcript = Self.carouselTranscript()

        store.startAnalysis(transcript: transcript, modelContext: context)
        let deadline = ContinuousClock.now + .seconds(600)
        while store.hasActiveJob || store.record(for: transcript.episodeID)?.state == .running {
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: .milliseconds(200))
        }

        let record = try #require(store.record(for: transcript.episodeID))
        let run = try #require(runs.records(limit: 1).first)
        let runFile = try Data(contentsOf: runs.directory.appending(path: "\(run.id).json"))
        Attachment.record(runFile, named: "run-record.json")
        let evidence: [String: Any] = [
            "status_mode": status?.mode.rawValue ?? "unreadable",
            "status_units_remaining": status?.unitsRemaining ?? -1,
            "status_month_paused": status?.monthPaused ?? false,
            "record_state": record.state.rawValue,
            "failure_kind": record.failureKind?.rawValue ?? "",
            "span_count": record.spanCount,
            "posts": connection.recorder.statuses,
            "calls": connection.recorder.usages.map {
                ["input": $0.input, "cached": $0.cached, "write": $0.write, "output": $0.output, "reasoning": $0.reasoning]
            },
        ]
        Attachment.record(try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted]), named: "trial-evidence.json")

        #expect(status != nil)
        #expect(run.route == .trial)
        #expect(run.state == .finished)
        #expect(record.state == .completed)
        #expect(EpisodeAdAnalysisContract.supports(policy: try #require(store.document(for: transcript.episodeID)).policy))
    }

    static func carouselTranscript() -> EpisodeTranscriptDocument {
        let rows: [(Int, Double, Double, String)] = [
        (10, 0.0, 160.0, "Welcome to Workbench Conversations. Today we are repairing a wooden boat. Inspect each plank for damage before removing the old paint. We tried CedarBright varnish last year; it cracked. This is a discussion of what failed, not a recommendation. We'll compare it with the old oil finish after a short break."),
        (20, 161.0, 173.0, "I'm Mira, and this is Harbor Letters, a new documentary podcast. A sealed envelope arrived thirty years after the boat disappeared."),
        (30, 173.0, 195.0, "I recognized his handwriting immediately. I never thought I would hear his voice again. When they opened the shed, the missing logbook was lying on the floor. What happened that winter? We followed every clue."),
        (40, 195.0, 210.0, "Listen to Harbor Letters on your favorite podcast app. Every Monday, discover the stories the harbor kept."),
        (50, 211.0, 241.0, "On Backstage Supper, actors tell us what happened after the curtain fell. I forgot my own name on opening night. Did the audience notice? Only when I answered to the wrong one! Join us for the whole conversation. Subscribe to Backstage Supper wherever you get podcasts."),
        (60, 242.0, 400.0, "We are back at the workbench. The repair is curing now. The old varnish had separated because moisture got under it. You can see why the entire plank must dry before applying a new finish."),
        (70, 400.0, 530.0, "A listener asked why old boat posters say listen to the sea. That slogan was advertising, but today we are studying the typography of those posters. Our fictional sponsor, Bottomless Bucket, never did keep the water out. That's a joke, not a real company. Now check the fasteners along the keel."),
        (80, 531.0, 543.0, "I'm Mira, and this is Harbor Letters, a new documentary podcast. A sealed envelope arrived thirty years after the boat disappeared."),
        (90, 543.0, 565.0, "I recognized his handwriting immediately. I never thought I would hear his voice again. When they opened the shed, the missing logbook was lying on the floor. What happened that winter? We followed every clue."),
        (100, 565.0, 580.0, "Listen to Harbor Letters on your favorite podcast app. Every Monday, discover the stories the harbor kept."),
        (110, 581.0, 791.0, "Back to the boat. Use a fresh brush for the final coat. Leave it alone overnight, then inspect the edges once more. That is the end of our woodworking lesson. Thank you for listening to Workbench Conversations. Goodbye."),
        (120, 792.0, 798.8, "Try our sister show, Five Minute Gardens. Subscribe wherever you listen to podcasts."),
        ]
        let segments = rows.map { row in
            OpenCastTranscriptSegment(id: row.0, start: row.1, end: row.2, text: row.3, avgLogProbability: -0.1, noSpeechProbability: 0.01)
        }
        let updatedAt = Date(timeIntervalSince1970: 1_792_000_000)
        return EpisodeTranscriptDocument(
            schemaVersion: 1,
            episodeID: "live-trial-carousel",
            podcastID: "live-trial-podcast",
            sourceAudioURL: "https://example.com/live-trial-carousel.mp3",
            sourceFileByteCount: 1,
            sourceFileSHA256: "live-trial",
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
}

/// The build's trial connection, with each analyze post's status and each
/// 2xx reply's billed usage recorded (numbers only).
private struct RecordingTrialConnection: AnalysisTrialConnecting {
    let inner: AnalysisTrialConnection
    let recorder = TrialPostRecorder()

    var isConfigured: Bool { inner.isConfigured }

    func exchange(trialEndpoint: URL) async -> (any AnalysisTrialProxyExchange)? {
        guard let exchange = await inner.exchange(trialEndpoint: trialEndpoint) else { return nil }
        return RecordingTrialExchange(inner: exchange, recorder: recorder)
    }
}

private final class TrialPostRecorder: Sendable {
    private let state = Mutex<(statuses: [Int], usages: [AnalysisBilledUsage])>(([], []))

    var statuses: [Int] { state.withLock { $0.statuses } }
    var usages: [AnalysisBilledUsage] { state.withLock { $0.usages } }

    func record(_ response: AnalysisHTTPResponse) {
        let usage = (200..<300).contains(response.status)
            ? String(validating: response.body, as: UTF8.self).flatMap { AnalysisBilledUsage.billed(provider: .google, body: $0) }
            : nil
        state.withLock { state in
            state.statuses.append(response.status)
            if let usage { state.usages.append(usage) }
        }
    }
}

private struct RecordingTrialExchange: AnalysisTrialProxyExchange {
    let inner: any AnalysisTrialProxyExchange
    let recorder: TrialPostRecorder

    func post(
        path: String,
        payloadText: String,
        timeoutSeconds: Double,
        maximumBodyBytes: Int
    ) async throws(AnalysisHTTPFailure) -> AnalysisHTTPResponse {
        let response = try await inner.post(path: path, payloadText: payloadText, timeoutSeconds: timeoutSeconds, maximumBodyBytes: maximumBodyBytes)
        if path == TrialProxyAnalysisTransport.analyzePath { recorder.record(response) }
        return response
    }
}
