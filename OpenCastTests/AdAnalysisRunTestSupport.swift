import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import SwiftData
import Synchronization
@testable import OpenCast

/// How the scripted transport answers one send.
nonisolated enum ScriptedAdAnswer: Sendable {
    /// A reply that validates: the window's first segment reading "brought
    /// to you" becomes one host-read break (no break when there is none).
    case sponsorRead
    /// A reply naming a segment the window does not have, so the window and
    /// its one corrective request fail validation.
    case unverifiableBreak
    /// The provider's refusal: `listener` is what the send reports.
    case failure(AnalysisTransportError, status: Int?, listener: AnalysisProviderFailure)
    /// Waits until the run is cancelled.
    case hold
}

/// Every request the scripted transport received, in arrival order.
nonisolated final class ScriptedAdSendLog: Sendable {
    private let requests = Mutex<[AnalysisProviderRequest]>([])

    func append(_ request: AnalysisProviderRequest) {
        requests.withLock { $0.append(request) }
    }

    var all: [AnalysisProviderRequest] {
        requests.withLock { $0 }
    }

    var count: Int {
        requests.withLock { $0.count }
    }

    func count(of purpose: AnalysisProviderRequest.Purpose) -> Int {
        requests.withLock { $0.filter { $0.purpose == purpose }.count }
    }

    /// The `{id, text}` segments of the first request's user turn.
    var firstSegments: [(id: Int64, text: String)] {
        guard let request = all.first,
              let text = request.payload["contents"]?.arrayValue?.first?["parts"]?.arrayValue?.first?["text"]?.stringValue,
              let input = try? JSONParser.parse(text),
              let segments = input["segments"]?.arrayValue
        else {
            return []
        }
        return segments.compactMap { segment in
            guard case .number(let number)? = segment["id"],
                  let id = Int64(exactly: number.doubleValue),
                  let text = segment["text"]?.stringValue
            else {
                return nil
            }
            return (id, text)
        }
    }
}

/// Answers each send as scripted and reports a send record for it, as a
/// real transport does. Never reaches the network.
nonisolated struct ScriptedAdAnalysisTransport: AnalysisProviderTransport {
    let answer: @Sendable (AnalysisProviderRequest) -> ScriptedAdAnswer
    let route: AnalysisRoute
    let observer: any AnalysisProviderSendObserver
    let log: ScriptedAdSendLog
    let gate: AsyncTestGate?

    func send(_ request: AnalysisProviderRequest) async throws(AnalysisTransportError) -> AnalysisProviderReply {
        log.append(request)
        if let gate {
            await gate.wait()
        }
        switch answer(request) {
        case .sponsorRead:
            record(request, status: 200, failure: nil, usage: Self.usage)
            return .geminiBody(AnalysisUITestFixtureTransport.adBody(for: request))
        case .unverifiableBreak:
            record(request, status: 200, failure: nil, usage: Self.usage)
            return .geminiBody(Self.unverifiableBody)
        case .failure(let error, let status, let listener):
            record(request, status: status, failure: listener)
            throw error
        case .hold:
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
            record(request, status: nil, failure: nil, cancelled: true)
            throw .network
        }
    }

    static let usage = AnalysisBilledUsage(input: 420, cached: 0, write: 0, output: 36, reasoning: 0)

    private func record(
        _ request: AnalysisProviderRequest,
        status: Int?,
        failure: AnalysisProviderFailure?,
        cancelled: Bool = false,
        usage: AnalysisBilledUsage? = nil
    ) {
        observer.record(AnalysisProviderSendRecord(
            provider: route == .trial ? .google : request.model.provider,
            modelID: request.model.modelID,
            feature: request.feature,
            purpose: request.purpose,
            sendIndex: request.sendIndex,
            status: status,
            finishReason: status == 200 ? .stop : nil,
            failure: failure,
            cancelled: cancelled,
            usage: usage,
            pacedSeconds: 0,
            exchangeSeconds: 0
        ))
    }

    /// A break whose boundaries name a segment no window has.
    private static let unverifiableBody: String = {
        let answer = JSONWriter.string(.object([JSONMember("spans", .array([.object([
            JSONMember("confidence", .number(.double(0.9))),
            JSONMember("end_quote", .string("not in this transcript")),
            JSONMember("end_segment_id", .integer(999_999)),
            JSONMember("evidence_quote", .string("not in this transcript")),
            JSONMember("kind", .string("host_read_ad")),
            JSONMember("label", .string("Missing")),
            JSONMember("start_quote", .string("not in this transcript")),
            JSONMember("start_segment_id", .integer(999_999)),
        ])]))]))
        return JSONWriter.string(.object([
            JSONMember("candidates", .array([.object([
                JSONMember("content", .object([
                    JSONMember("parts", .array([.object([JSONMember("text", .string(answer))])])),
                    JSONMember("role", .string("model")),
                ])),
                JSONMember("finishReason", .string("STOP")),
            ])])),
            JSONMember("usageMetadata", .object([
                JSONMember("candidatesTokenCount", .integer(36)),
                JSONMember("promptTokenCount", .integer(420)),
                JSONMember("totalTokenCount", .integer(456)),
            ])),
        ]))
    }()
}

/// Time for the run budget that never passes, so backoff never waits.
nonisolated struct StoppedAnalysisClock: AnalysisClock {
    func now() -> Double { 0 }
    func sleep(seconds: Double) async throws {}
}

/// A run environment for store tests: the baked policy, a fake key, run
/// records in a temporary directory and a scripted transport; it records
/// every route, usage, trial refresh and key screen the store asks for.
@MainActor
final class ScriptedAdAnalysisRunEnvironment: EpisodeAdAnalysisRunEnvironment {
    struct Usage: Equatable {
        var provider: AnalysisProvider
        var inputTokens: Int
        var outputTokens: Int
        var runID: String
    }

    let runs: AnalysisRunRecordStore
    let clock: any AnalysisClock = StoppedAnalysisClock()
    let snapshot = AnalysisPolicySnapshot.baked
    var adDetectionPolicyRevision: String
    var holdsContinuedProcessingCard = false
    /// The route new runs resolve to.
    var route: AnalysisRoute = .direct(provider: .google)
    /// Replaces the direct route's model per-call timeout.
    var perCallTimeoutSeconds: Int?
    /// Whether a resumed run keeps its route; `false` resolves it as new.
    var keepsResumedRoute = true
    /// The answer for every send; `answerForRun` (by the run's 1-based
    /// transport count) and then `answerForRequest` override it.
    var answer: ScriptedAdAnswer = .sponsorRead
    var answerForRun: ((Int) -> ScriptedAdAnswer?)?
    var answerForRequest: (@Sendable (AnalysisProviderRequest) -> ScriptedAdAnswer)?
    /// Holds every send until released.
    var gate: AsyncTestGate?
    let sends = ScriptedAdSendLog()
    private(set) var resolvedRunIDs: [String?] = []
    private(set) var transportRunIDs: [String] = []
    private(set) var usage: [Usage] = []
    /// The run record's state when each usage was recorded.
    private(set) var usageRunStates: [AnalysisRunRecord.State?] = []
    /// Counts usage in this store when set; its save decides the result.
    var usageStore: AnalysisUsageStore?
    private(set) var trialRefreshCount = 0
    private(set) var presentedReasons: [AnalysisKeyRequiredReason] = []
    /// The key every direct resolution carries.
    static let key = AnalysisProviderKey("scripted-test-key")!
    /// When set, direct runs send through the key guard over this storage,
    /// as the app's transports do.
    var keyStorage: InMemoryAnalysisProviderKeyStorage?
    private let keyRemovals = AnalysisKeyRemovalLog()
    /// Called at each send, before it is answered.
    var onSend: (@Sendable (AnalysisProviderRequest) -> Void)?

    init(directory: URL = FileManager.default.temporaryDirectory
        .appending(path: "OpenCastAdRunRecords-\(UUID().uuidString)", directoryHint: .isDirectory)) {
        runs = AnalysisRunRecordStore(directory: directory)
        adDetectionPolicyRevision = AnalysisPolicySnapshot.baked.bundle.features.adDetection.revision
    }

    func resolveRoute(resumingRunID: String?) async -> AnalysisRouteResolution {
        resolvedRunIDs.append(resumingRunID)
        if let resumingRunID, keepsResumedRoute,
           let record = runs.record(id: resumingRunID),
           record.state == .dispatched || record.state == .expired {
            let route: AnalysisRoute = record.route == .trial ? .trial : .direct(provider: record.provider)
            return resolution(route, resumingRunID: resumingRunID)
        }
        return resolution(route, resumingRunID: nil)
    }

    private func resolution(_ route: AnalysisRoute, resumingRunID: String?) -> AnalysisRouteResolution {
        switch route {
        case .keyRequired(let reason):
            return .keyRequired(reason, feature: .adDetection)
        case .direct(let provider):
            let timeout = perCallTimeoutSeconds
            let policy = snapshot.adDetection(provider: provider).map { policy in
                guard let timeout else { return policy }
                var model = policy.model
                model.perCallTimeoutSeconds = timeout
                return policy.with(model: model)
            }
            return AnalysisRouteResolution(
                feature: .adDetection,
                route: route,
                policy: policy.map(AnalysisRoutePolicy.adDetection),
                key: Self.key,
                resumingRunID: resumingRunID,
                trialExchange: nil
            )
        case .trial:
            return AnalysisRouteResolution(
                feature: .adDetection,
                route: .trial,
                policy: AnalysisRouteResolver.trialPolicy(feature: .adDetection, snapshot: snapshot),
                key: nil,
                resumingRunID: resumingRunID,
                trialExchange: AnalysisUITestTrialProxyExchange()
            )
        }
    }

    func makeTransport(
        for resolution: AnalysisRouteResolution,
        runID: String,
        observer: any AnalysisProviderSendObserver,
        onReused: @escaping @Sendable (AnalysisProviderRequest) -> Void
    ) throws(AnalysisTransportFactoryError) -> any AnalysisProviderTransport {
        if let reason = resolution.keyRequiredReason {
            throw .keyRequired(reason)
        }
        transportRunIDs.append(runID)
        let fixed = answerForRun?(transportRunIDs.count) ?? answer
        let perRequest = answerForRequest
        let onSend = onSend
        var inner: any AnalysisProviderTransport = ScriptedAdAnalysisTransport(
            answer: { request in
                onSend?(request)
                return perRequest?(request) ?? fixed
            },
            route: resolution.route,
            observer: observer,
            log: sends,
            gate: gate
        )
        if let keyStorage, case .direct(let provider) = resolution.route, let key = resolution.key {
            let removals = keyRemovals
            inner = AnalysisKeyPresenceGuardTransport(
                inner: inner,
                provider: provider,
                keyDigest: key.digest,
                keys: keyStorage,
                observer: observer,
                onRemoval: { reason in removals.record(reason, runID: runID) }
            )
        }
        return AnalysisResumingTransport(inner: inner, store: runs, runID: runID, onReused: onReused)
    }

    func recordUsage(
        provider: AnalysisProvider,
        inputTokens: Int,
        outputTokens: Int,
        runID: String,
        modelContext: ModelContext
    ) -> Bool {
        usage.append(Usage(provider: provider, inputTokens: inputTokens, outputTokens: outputTokens, runID: runID))
        usageRunStates.append(runs.record(id: runID)?.state)
        return usageStore?.record(
            provider: provider,
            feature: .adDetection,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            at: .now,
            runID: runID,
            modelContext: modelContext
        ) ?? true
    }

    func keyRemoval(runID: String) -> AnalysisKeyRequiredReason? {
        keyRemovals.reason(runID: runID)
    }

    func refreshTrialStatus() {
        trialRefreshCount += 1
    }

    func presentKeyRequired(_ reason: AnalysisKeyRequiredReason) {
        presentedReasons.append(reason)
    }

    /// The newest run record.
    var latestRun: AnalysisRunRecord? {
        runs.records(limit: 1).first
    }
}

/// A job client for stores whose runs never reach the analysis service; it
/// counts the polls a test expects never to happen.
nonisolated final class UnpolledAdAnalysisClient: EpisodeAdAnalysisClient {
    private let polls = Mutex(0)

    var pollCount: Int {
        polls.withLock { $0 }
    }

    func pollJob(id: String) async throws -> EpisodeAdAnalysisJobPollOutcome {
        polls.withLock { $0 += 1 }
        throw EpisodeAdAnalysisError.clientDisabled
    }
}
