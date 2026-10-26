import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import Synchronization
import Testing
@testable import OpenCast

/// A small synthetic episode the analysis suites share: 14 segments of 30
/// seconds in windows of 6 with an overlap of 2 (three windows), and a
/// sponsor read in segment 6, which only window 1 sees.
nonisolated enum AnalysisRunTestFixtures {
    static let segmentCount = 14
    static let adSegmentIndex = 6
    static let windowCount = 3

    static var snapshot: AnalysisPolicySnapshot {
        var bundle = AnalysisPolicyBundle.baked
        bundle.features.adDetection.window.segments = 6
        bundle.features.adDetection.window.overlap = 2
        return AnalysisPolicySnapshot(bundle: bundle, source: .baked, fallbackReason: nil, lastRefreshFailure: nil)
    }

    static func segmentText(_ index: Int) -> String {
        if index == adSegmentIndex {
            return "This episode is brought to you by Acme Tools. Use code WORKBENCH for ten percent off your first order."
        }
        return "Part \(index) of the repair: we sand plank number \(index) and check the grain before the next coat."
    }

    static func request(replacingSegment replaced: Int? = nil) -> AdAnalysisRequest {
        let segments = (0..<segmentCount).map { index in
            AnalysisSegment(
                id: Int64(index),
                start: Double(index) * 30,
                end: Double(index + 1) * 30,
                text: index == replaced ? "A different sentence about the varnish on plank \(index)." : segmentText(index)
            )
        }
        return AdAnalysisRequest(
            requestID: "request-1",
            episodeID: "episode-1",
            podcastID: "podcast-1",
            episodeTitle: "Repairing a wooden boat",
            podcastTitle: "Workbench Conversations",
            transcript: AdAnalysisTranscript(
                languageCode: "en",
                audioDuration: Double(segmentCount) * 30,
                fingerprint: "fixture-fingerprint",
                updatedAt: "2026-10-25T00:00:00Z",
                segmentCount: segmentCount
            ),
            segments: segments
        )
    }

    /// The model's answer for one window: the sponsor read in window 1,
    /// nothing elsewhere.
    static func answer(window: Int) -> String {
        guard window == 1 else { return #"{"spans":[]}"# }
        return #"{"spans":[{"kind":"host_read_ad","label":"Acme Tools","start_segment_id":6,"end_segment_id":6,"confidence":0.92,"evidence_quote":"brought to you by Acme Tools","start_quote":"This episode is brought to you by Acme Tools","end_quote":"ten percent off your first order"}]}"#
    }

    static func geminiBody(_ answer: String) -> String {
        let object: [String: Any] = [
            "candidates": [["content": ["parts": [["text": answer]]], "finishReason": "STOP"]],
            "usageMetadata": ["promptTokenCount": 100, "candidatesTokenCount": 20, "thoughtsTokenCount": 5, "totalTokenCount": 125],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// The window an ad-detection request belongs to, read from its payload.
    static func window(of request: AnalysisProviderRequest) -> Int {
        request.purpose.windowIndex ?? 0
    }

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "analysis-runs-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// A finished ad-detection outcome for the synthetic episode.
    static func successfulOutcome() async -> AnalysisOutcome {
        let policy = AnalysisRouteResolver.trialPolicy(feature: .adDetection, snapshot: snapshot)!.adDetection!
        return await AnalysisRunner(transport: AnsweringTransport()).detectAds(request(), policy: policy)
    }
}

/// Answers every window with the fixture answer, without any exchange.
nonisolated struct AnsweringTransport: AnalysisProviderTransport {
    func send(_ request: AnalysisProviderRequest) async throws(AnalysisTransportError) -> AnalysisProviderReply {
        .geminiBody(AnalysisRunTestFixtures.geminiBody(AnalysisRunTestFixtures.answer(window: AnalysisRunTestFixtures.window(of: request))))
    }
}

/// A trial exchange that records each post's wrapper fields and answers
/// with the fixture's Gemini body for the post's window.
nonisolated final class RecordingTrialProxyExchange: AnalysisTrialProxyExchange {
    struct Post: Sendable, Equatable {
        var path: String
        var feature: String
        var runID: String
        var windowIndex: Int
    }

    private let state = Mutex<(posts: [Post], cancelsNext: Bool)>(([], false))

    var posts: [Post] {
        state.withLock { $0.posts }
    }

    /// The next post cancels the task that sends it once it is answered, as
    /// a killed app stops the run after a reply arrived.
    func cancelAfterNextReply() {
        state.withLock { $0.cancelsNext = true }
    }

    func post(
        path: String,
        payloadText: String,
        timeoutSeconds: Double,
        maximumBodyBytes: Int
    ) async throws(AnalysisHTTPFailure) -> AnalysisHTTPResponse {
        guard let object = try? JSONSerialization.jsonObject(with: Data(payloadText.utf8)) as? [String: Any],
              let feature = object["feature"] as? String,
              let runID = object["run_id"] as? String,
              let windowIndex = object["window_index"] as? Int
        else {
            throw .network
        }
        let cancels = state.withLock { state in
            state.posts.append(Post(path: path, feature: feature, runID: runID, windowIndex: windowIndex))
            defer { state.cancelsNext = false }
            return state.cancelsNext
        }
        if cancels {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let body = AnalysisRunTestFixtures.geminiBody(AnalysisRunTestFixtures.answer(window: windowIndex))
        return AnalysisHTTPResponse(status: 200, contentType: "application/json", body: Data(body.utf8))
    }
}

/// The trial connection a test configures: whether the build has a route,
/// and the exchange it hands out.
nonisolated final class FixedTrialConnection: AnalysisTrialConnecting {
    let isConfigured: Bool
    private let current: (any AnalysisTrialProxyExchange)?
    private let calls = Mutex(0)

    init(exchange: (any AnalysisTrialProxyExchange)?, isConfigured: Bool = true) {
        current = exchange
        self.isConfigured = isConfigured
    }

    var exchangeCalls: Int {
        calls.withLock { $0 }
    }

    func exchange(trialEndpoint: URL) async -> (any AnalysisTrialProxyExchange)? {
        calls.withLock { $0 += 1 }
        return current
    }
}

/// A count shared with escaping closures.
nonisolated final class AnalysisTestCounter: Sendable {
    private let value = Mutex(0)

    var count: Int {
        value.withLock { $0 }
    }

    func add() {
        value.withLock { $0 += 1 }
    }
}

/// Counts every request a transport would send, answering none.
nonisolated final class CountingTransport: AnalysisProviderTransport {
    private let requests = Mutex<[AnalysisProviderRequest]>([])

    var sent: [AnalysisProviderRequest] {
        requests.withLock { $0 }
    }

    func send(_ request: AnalysisProviderRequest) async throws(AnalysisTransportError) -> AnalysisProviderReply {
        requests.withLock { $0.append(request) }
        throw .rejected(status: 400)
    }
}

@MainActor
@Suite("Analysis run resume")
struct AnalysisRunResumeTests {
    /// One launch's route pieces over a run directory.
    struct Launch {
        let runs: AnalysisRunRecordStore
        let resolver: AnalysisRouteResolver
        let factory: AnalysisTransportFactory
        let defaults: UserDefaults
    }

    let suiteName = "opencast-analysis-resume-tests-\(UUID().uuidString)"

    func launch(directory: URL, exchange: RecordingTrialProxyExchange, status: AnalysisTrialProxyStatus?) -> Launch {
        let runs = AnalysisRunRecordStore(directory: directory)
        let policy = AnalysisPolicySnapshotStore.fixed(AnalysisRunTestFixtures.snapshot)
        let defaults = UserDefaults(suiteName: suiteName)!
        // Each launch reads the status afresh.
        defaults.removePersistentDomain(forName: suiteName)
        let resolver = AnalysisRouteResolver(
            keys: AnalysisProviderKeyStore(storage: InMemoryAnalysisProviderKeyStorage()),
            policy: policy,
            storedProvider: { _ in .google },
            trialStatus: AnalysisTrialStatusCache(defaults: defaults, fetch: { status }),
            trial: FixedTrialConnection(exchange: exchange),
            runs: runs
        )
        return Launch(
            runs: runs,
            resolver: resolver,
            factory: AnalysisTransportFactory(policy: policy, runs: runs, keys: InMemoryAnalysisProviderKeyStorage()),
            defaults: defaults
        )
    }

    /// Resolves, writes the record when the run is new, builds the
    /// transport and runs the synthetic episode, as the store does; never
    /// finishes the record.
    func execute(
        _ launch: Launch,
        runID: String,
        resuming: Bool,
        request: AdAnalysisRequest = AnalysisRunTestFixtures.request(),
        reused: AnalysisTestCounter? = nil
    ) async throws -> (AnalysisRouteResolution, AnalysisOutcome) {
        let resolution = await launch.resolver.resolve(feature: .adDetection, resumingRunID: resuming ? runID : nil)
        let policy = try #require(resolution.policy)
        if !resuming {
            try launch.runs.begin(AnalysisRunRecord(
                id: runID,
                feature: .adDetection,
                episodeID: request.episodeID,
                podcastID: request.podcastID,
                transcriptFingerprint: request.transcript.fingerprint,
                resolution: resolution,
                policy: policy
            ))
        }
        let transport = try launch.factory.makeTransport(
            for: resolution,
            runID: runID,
            observer: launch.runs.observer(runID: runID),
            onReused: { _ in reused?.add() }
        )
        let outcome = await AnalysisRunner(transport: transport).detectAds(request, policy: try #require(policy.adDetection))
        return (resolution, outcome)
    }

    @Test("A trial run killed after its first reply resumes under the same id, sends only the rest, and matches an uninterrupted run")
    func resumeSendsOnlyTheRest() async throws {
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let directory = AnalysisRunTestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runID = UUID().uuidString
        let exchange = RecordingTrialProxyExchange()

        // First launch: the trial has one unit; the run is killed once
        // window 0's reply is in.
        let first = launch(directory: directory, exchange: exchange, status: .init(mode: .trial, unitsRemaining: 1, startsAt: .now, monthPaused: false))
        exchange.cancelAfterNextReply()
        let (firstResolution, killed) = try await execute(first, runID: runID, resuming: false)
        #expect(firstResolution.route == .trial)
        #expect(firstResolution.policy?.adDetection?.settings.window.maxInFlight == 1)
        guard case .failed(let failure) = killed else {
            Issue.record("expected the killed run to stop, got \(killed)")
            return
        }
        #expect(failure.code == .cancelled)
        #expect(exchange.posts.map(\.windowIndex) == [0])
        #expect(first.runs.record(id: runID)?.state == .dispatched)
        #expect(first.runs.replies(runID: runID).count == 1)

        // Next launch: the trial reports no units left; the run resumes
        // under its id anyway and sends only windows 1 and 2.
        let second = launch(directory: directory, exchange: exchange, status: .init(mode: .trial, unitsRemaining: 0, startsAt: .now, monthPaused: false))
        let reused = AnalysisTestCounter()
        let (resumed, outcome) = try await execute(second, runID: runID, resuming: true, reused: reused)
        #expect(resumed.route == .trial)
        #expect(resumed.resumingRunID == runID)
        #expect(exchange.posts.map(\.windowIndex) == [0, 1, 2])
        #expect(exchange.posts.allSatisfy { $0.runID == runID && $0.feature == "ad_detection" && $0.path == TrialProxyAnalysisTransport.analyzePath })
        #expect(reused.count == 1)

        // The same outcome as a run that was never interrupted.
        let uninterrupted = launch(directory: AnalysisRunTestFixtures.temporaryDirectory(), exchange: RecordingTrialProxyExchange(), status: .init(mode: .open, unitsRemaining: 0, startsAt: .now, monthPaused: false))
        defer { try? FileManager.default.removeItem(at: uninterrupted.runs.directory) }
        let (_, expected) = try await execute(uninterrupted, runID: UUID().uuidString, resuming: false)
        guard case .adDetection(let response) = expected else {
            Issue.record("expected the uninterrupted run to finish, got \(expected)")
            return
        }
        #expect(response.spans.map(\.startSegmentID) == [Int64(AnalysisRunTestFixtures.adSegmentIndex)])
        #expect(outcome == expected)

        // The record's totals accumulate across both executions.
        let record = try #require(second.runs.record(id: runID))
        let perWindow = try #require(AnalysisBilledUsage.billed(provider: .google, body: AnalysisRunTestFixtures.geminiBody(#"{"spans":[]}"#)))
        #expect(record.inputTokens == perWindow.input * 3)
        #expect(record.outputTokens == perWindow.output * 3)
        #expect(record.windows.keys.sorted() == ["0", "1", "2"])
        #expect(record.windows.values.allSatisfy { $0.sends == 1 && $0.verdict == .answered })
        #expect(record.exchangeSeconds >= 0)

        second.runs.finish(runID: runID, outcome: outcome, listenerFailure: nil, background: false)
        #expect(second.runs.record(id: runID)?.state == .finished)
        #expect(second.runs.replies(runID: runID).isEmpty)
    }

    @Test("A kept reply is not reused for a window whose payload bytes changed")
    func changedBytesAreSentAgain() async throws {
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let directory = AnalysisRunTestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runID = UUID().uuidString
        let exchange = RecordingTrialProxyExchange()
        let status = AnalysisTrialProxyStatus(mode: .open, unitsRemaining: 0, startsAt: .now, monthPaused: false)

        let first = launch(directory: directory, exchange: exchange, status: status)
        exchange.cancelAfterNextReply()
        _ = try await execute(first, runID: runID, resuming: false)
        #expect(exchange.posts.map(\.windowIndex) == [0])

        // Segment 1 sits in window 0 only: that window's bytes change.
        let second = launch(directory: directory, exchange: exchange, status: status)
        let reused = AnalysisTestCounter()
        let (_, outcome) = try await execute(
            second,
            runID: runID,
            resuming: true,
            request: AnalysisRunTestFixtures.request(replacingSegment: 1),
            reused: reused
        )
        #expect(exchange.posts.map(\.windowIndex) == [0, 0, 1, 2])
        #expect(reused.count == 0)
        guard case .adDetection = outcome else {
            Issue.record("expected the resumed run to finish, got \(outcome)")
            return
        }
    }

    @Test("A kept reply answers only its own purpose and the same bytes")
    func replyKeyedByPurposeAndBytes() async throws {
        let directory = AnalysisRunTestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AnalysisRunRecordStore(directory: directory)
        let runID = "reply-key-run"
        let policy = try #require(AnalysisRouteResolver.trialPolicy(feature: .adDetection, snapshot: AnalysisRunTestFixtures.snapshot)?.adDetection)

        let capture = CountingTransport()
        _ = await AnalysisRunner(transport: capture).detectAds(AnalysisRunTestFixtures.request(), policy: policy)
        let request = try #require(capture.sent.first)
        let kept = AnalysisProviderReply.geminiBody(AnalysisRunTestFixtures.geminiBody(#"{"spans":[]}"#))
        store.saveReply(AnalysisRunStoredReply(kept), for: AnalysisRunReplyKey(request), runID: runID)

        let inner = CountingTransport()
        let reused = AnalysisTestCounter()
        let transport = AnalysisResumingTransport(inner: inner, store: store, runID: runID, onReused: { _ in reused.add() })
        #expect(try await transport.send(request) == kept)
        #expect(inner.sent.isEmpty)
        #expect(reused.count == 1)

        var changed = request
        changed.payloadText += " "
        await #expect(throws: AnalysisTransportError.rejected(status: 400)) { _ = try await transport.send(changed) }
        var repair = request
        repair.purpose = .adRepair(index: 0)
        await #expect(throws: AnalysisTransportError.rejected(status: 400)) { _ = try await transport.send(repair) }
        #expect(inner.sent.count == 2)
        #expect(reused.count == 1)

        // A failed send keeps nothing.
        #expect(store.replies(runID: runID).count == 1)
    }

    @Test("Every 2xx the provider answers is kept, and a later attempt reads it back")
    func repliesKeptAcrossInstances() async throws {
        let directory = AnalysisRunTestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runID = "kept-replies-run"
        let policy = try #require(AnalysisRouteResolver.trialPolicy(feature: .adDetection, snapshot: AnalysisRunTestFixtures.snapshot)?.adDetection)
        let store = AnalysisRunRecordStore(directory: directory)
        let transport = AnalysisResumingTransport(inner: AnsweringTransport(), store: store, runID: runID)
        _ = await AnalysisRunner(transport: transport).detectAds(AnalysisRunTestFixtures.request(), policy: policy)

        let relaunched = AnalysisRunRecordStore(directory: directory)
        let kept = relaunched.replies(runID: runID)
        #expect(kept.count == AnalysisRunTestFixtures.windowCount)
        #expect(Set(kept.keys.map(\.purpose)) == ["ad_window_0", "ad_window_1", "ad_window_2"])
        #expect(kept.keys.allSatisfy { $0.payloadSHA256.count == 64 })

        let inner = CountingTransport()
        let outcome = await AnalysisRunner(transport: AnalysisResumingTransport(inner: inner, store: relaunched, runID: runID))
            .detectAds(AnalysisRunTestFixtures.request(), policy: policy)
        #expect(inner.sent.isEmpty)
        let expected = await AnalysisRunTestFixtures.successfulOutcome()
        #expect(outcome == expected)
    }
}
