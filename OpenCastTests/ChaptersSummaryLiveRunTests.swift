import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import SwiftData
import Testing
@testable import OpenCast

/// Chapters & Summary through the producer, the real transport and the real
/// provider, on a short synthetic transcript. Each test runs only where the
/// environment names a readable key file (`TEST_RUNNER_<variable>` on the
/// xcodebuild environment); the key is read by path, never printed, attached
/// or saved to the Keychain. With `OPENCAST_ANALYSIS_LIVE_SUMMARY_DIR` set,
/// the run's billed token counts are written there as numbers only.
@MainActor
@Suite("Chapters & Summary live run")
struct ChaptersSummaryLiveRunTests {
    @Test("A Google key named by the environment runs Chapters & Summary end to end", .enabled(if: LiveRun.keyPath(for: .google) != nil))
    func googleRun() async throws {
        try await run(.google)
    }

    @Test("An OpenAI key named by the environment runs Chapters & Summary end to end", .enabled(if: LiveRun.keyPath(for: .openai) != nil))
    func openAIRun() async throws {
        try await run(.openai)
    }

    private func run(_ provider: AnalysisProvider) async throws {
        guard let path = LiveRun.keyPath(for: provider),
              let key = AnalysisProviderKey(try String(contentsOfFile: path, encoding: .utf8))
        else {
            Issue.record("No readable key file for \(provider.rawValue)")
            return
        }
        let directory = URL.temporaryDirectory.appending(path: "chapters-live-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runs = AnalysisRunRecordStore(directory: directory)
        let policyStore = AnalysisPolicySnapshotStore.fixed(.baked)
        let factory = AnalysisTransportFactory(
            policy: policyStore,
            runs: runs,
            keys: InMemoryAnalysisProviderKeyStorage(seeded: [provider: (key, syncs: false)])
        )
        let session = AnalysisExecutionSession(
            identifier: AnalysisContinuedTaskArbiterImpl.chaptersSummaryIdentifier,
            title: "Chapters & Summary",
            scheduler: ForegroundOnlyScheduler(),
            arbiter: nil
        )
        let routePolicy = try #require(
            AnalysisRouteResolver.directPolicy(feature: .chaptersSummary, provider: provider, snapshot: .baked)
        )
        let resolution = AnalysisRouteResolution(
            feature: .chaptersSummary,
            route: .direct(provider: provider),
            policy: routePolicy,
            key: key,
            resumingRunID: nil,
            trialExchange: nil
        )
        var usage: (input: Int, output: Int)?
        let producer = ChaptersSummaryRunProducer(dependencies: ChaptersSummaryRunProducer.Dependencies(
            resolve: { _ in resolution },
            runs: runs,
            makeTransport: { resolution, runID, observer throws(AnalysisTransportFactoryError) in
                try factory.makeTransport(for: resolution, runID: runID, observer: observer)
            },
            session: session,
            recordUsage: { _, input, output, _, _ in
                usage = (input, output)
                return true
            },
            presentKeyRequired: { _ in },
            refreshTrialStatus: {}
        ))
        let request = LiveRun.request()
        let context = ModelContext(try OpenCastModelContainerFactory.make(inMemory: true))

        let result = await producer.run(request, modelContext: context)

        let record = try #require(runs.record(id: request.runID))
        try LiveRun.writeSummary(provider: provider, record: record)
        guard case .completed(let response, let completion) = result else {
            Issue.record("The \(provider.rawValue) run did not complete: \(String(describing: record.outcomeCode)) \(String(describing: record.listenerFailure))")
            return
        }
        producer.finish(completion)
        #expect(response.policy == EpisodeTranscriptAnalysisContract.expectedPolicy)
        #expect(response.schemaVersion == EpisodeTranscriptAnalysisContract.schemaVersion)
        #expect(response.requestID == request.runID)
        #expect(!response.chapters.isEmpty)
        let ids = Set(request.analysisRequest.segments.map(\.id))
        #expect(response.chapters.allSatisfy { ids.contains(Int64($0.startSegmentID)) && ids.contains(Int64($0.endSegmentID)) })
        #expect(response.summary.map { !$0.summary.isEmpty } == true)
        #expect(runs.record(id: request.runID)?.state == .finished)
        #expect((usage?.input ?? 0) > 0)
        #expect((usage?.output ?? 0) > 0)
    }
}

private enum LiveRun {
    static func keyPath(for provider: AnalysisProvider) -> String? {
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

    /// Ids, the outcome and token counts only.
    static func writeSummary(provider: AnalysisProvider, record: AnalysisRunRecord) throws {
        guard let directory = ProcessInfo.processInfo.environment["OPENCAST_ANALYSIS_LIVE_SUMMARY_DIR"] else {
            return
        }
        let summary: [String: Any] = [
            "provider": provider.rawValue,
            "model": record.modelID,
            "run_id": record.id,
            "state": record.state.rawValue,
            "outcome_code": record.outcomeCode ?? NSNull(),
            "listener_failure": record.listenerFailure ?? NSNull(),
            "sends": record.windows.values.reduce(0) { $0 + $1.sends },
            "input_tokens": record.inputTokens,
            "output_tokens": record.outputTokens,
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: URL(filePath: directory).appending(path: "\(provider.rawValue).json"))
    }

    /// A short synthetic episode written for this test: no listener's
    /// transcript.
    static func request() -> ChaptersSummaryRunRequest {
        let lines = [
            "Welcome to Kitchen Notes, the show about cooking at home.",
            "Today we are making a simple loaf of sourdough bread from scratch.",
            "First, feed the starter the night before so it is active and bubbly.",
            "Mix flour, water and the starter, then let the dough rest for an hour.",
            "Add salt and fold the dough every half hour for the next three hours.",
            "Shape the loaf gently and let it rise in the fridge overnight.",
            "In the morning, bake it in a hot covered pot for twenty minutes.",
            "Remove the lid and bake another twenty minutes until the crust is dark.",
            "Let the bread cool for an hour before you slice it.",
            "Next week we will talk about soups that go well with fresh bread. Thanks for listening.",
        ]
        let segments = lines.enumerated().map { index, text in
            AnalysisSegment(id: Int64(index), start: Double(index) * 30, end: Double(index + 1) * 30, text: text)
        }
        let runID = UUID().uuidString
        return ChaptersSummaryRunRequest(
            runID: runID,
            isResume: false,
            startedByListener: true,
            episodeID: "live-synthetic-episode",
            podcastID: "https://example.com/kitchen-notes.xml",
            episodeTitle: "Sourdough at Home",
            transcriptFingerprint: "live-synthetic-fingerprint",
            analysisRequest: TranscriptAnalysisRequest(
                requestID: runID,
                episodeID: "live-synthetic-episode",
                podcastID: "https://example.com/kitchen-notes.xml",
                episodeTitle: "Sourdough at Home",
                podcastTitle: "Kitchen Notes",
                transcript: TranscriptAnalysisTranscript(
                    languageCode: "en",
                    audioDuration: 300,
                    fingerprint: "live-synthetic-fingerprint",
                    updatedAt: "2026-10-25T12:00:00Z",
                    segmentCount: segments.count
                ),
                segments: segments
            )
        )
    }
}

@MainActor
private final class ForegroundOnlyScheduler: AnalysisContinuedTaskScheduling {
    func registerLaunchHandler(
        identifier: String,
        onLaunch: @escaping @MainActor @Sendable (any AnalysisContinuedTaskHandle) -> Void
    ) -> Bool {
        false
    }

    func submit(identifier: String, title: String, subtitle: String) async throws {}

    func cancel(identifier: String) {}
}
