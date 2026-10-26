import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import Security
import Synchronization
import Testing
@testable import OpenCast

/// Answers every send with a reply that validates and counts the sends that
/// reached it; `onArrival` runs with each arrival's 1-based count first.
nonisolated final class CountingAdTransport: AnalysisProviderTransport {
    private let arrivals = Mutex(0)
    private let onArrival: @Sendable (Int) async -> Void

    init(onArrival: @escaping @Sendable (Int) async -> Void = { _ in }) {
        self.onArrival = onArrival
    }

    var count: Int {
        arrivals.withLock { $0 }
    }

    func send(_ request: AnalysisProviderRequest) async throws(AnalysisTransportError) -> AnalysisProviderReply {
        let arrival = arrivals.withLock { count in
            count += 1
            return count
        }
        await onArrival(arrival)
        return .geminiBody(AnalysisUITestFixtureTransport.adBody(for: request))
    }
}

/// Turns the Keychain read fault on and off.
nonisolated final class KeychainReadFault: Sendable {
    private let on = Mutex(false)

    func set(_ value: Bool) {
        on.withLock { $0 = value }
    }

    var storageFault: InMemoryAnalysisProviderKeyStorage.Fault {
        { [self] operation, _ in
            operation == .read && on.withLock { $0 } ? errSecInteractionNotAllowed : nil
        }
    }
}

/// The in-memory key store, counting the key reads a run makes.
nonisolated final class CountingKeyStorage: AnalysisProviderKeyStoring {
    let inner: InMemoryAnalysisProviderKeyStorage
    private let readCount = Mutex(0)

    init(_ inner: InMemoryAnalysisProviderKeyStorage) {
        self.inner = inner
    }

    var reads: Int {
        readCount.withLock { $0 }
    }

    func save(_ key: AnalysisProviderKey, provider: AnalysisProvider, syncs: Bool) throws(AnalysisProviderKeyStoreError) {
        try inner.save(key, provider: provider, syncs: syncs)
    }

    func key(for provider: AnalysisProvider) throws(AnalysisProviderKeyStoreError) -> AnalysisProviderKey? {
        readCount.withLock { $0 += 1 }
        return try inner.key(for: provider)
    }

    func remove(provider: AnalysisProvider, includingSyncedCopy: Bool) throws(AnalysisProviderKeyStoreError) {
        try inner.remove(provider: provider, includingSyncedCopy: includingSyncedCopy)
    }

    func setSyncs(_ syncs: Bool, provider: AnalysisProvider) throws(AnalysisProviderKeyStoreError) {
        try inner.setSyncs(syncs, provider: provider)
    }

    func removeSyncedCopy(provider: AnalysisProvider) throws(AnalysisProviderKeyStoreError) {
        try inner.removeSyncedCopy(provider: provider)
    }

    func presence(for provider: AnalysisProvider) throws(AnalysisProviderKeyStoreError) -> AnalysisKeyPresence {
        try inner.presence(for: provider)
    }

    func syncedCopyExists(for provider: AnalysisProvider) throws(AnalysisProviderKeyStoreError) -> Bool {
        try inner.syncedCopyExists(for: provider)
    }
}

/// Answers provider sends from a script, then refuses them; counts every
/// send that left.
nonisolated final class ScriptedProviderHTTPClient: AnalysisHTTPClient {
    private let state: Mutex<(responses: [AnalysisHTTPResponse], sent: Int)>

    init(_ responses: [AnalysisHTTPResponse] = []) {
        state = Mutex((responses, 0))
    }

    var sentCount: Int {
        state.withLock { $0.sent }
    }

    func send(
        _ request: AnalysisHTTPRequest,
        timeoutSeconds: Double,
        maximumBodyBytes: Int
    ) async throws(AnalysisHTTPFailure) -> AnalysisHTTPResponse {
        state.withLock { state in
            state.sent += 1
            return state.responses.isEmpty
                ? AnalysisHTTPResponse(
                    status: 400,
                    contentType: "application/json",
                    body: Data(#"{"error":{"code":400,"message":"fixture refusal","status":"INVALID_ARGUMENT"}}"#.utf8)
                )
                : state.responses.removeFirst()
        }
    }
}

/// A pacer clock whose time moves only when the test ends its sleeps. A
/// cancelled sleep ends at once with `CancellationError`, so a test that
/// gives up on its precondition can cancel its run and await it.
nonisolated final class GatedPacingClock: AnalysisClock, Sendable {
    private struct Sleeper {
        var id: Int
        var seconds: Double
        var continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var now: Double = 0
        var nextID = 0
        var sleepers: [Sleeper] = []
        /// Sleeps cancelled before they registered.
        var cancelled: Set<Int> = []
    }

    private let state = Mutex(State())

    func now() -> Double {
        state.withLock { $0.now }
    }

    func sleep(seconds: Double) async throws {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let endsNow = state.withLock { state in
                    if state.cancelled.remove(id) != nil { return true }
                    state.sleepers.append(Sleeper(id: id, seconds: seconds, continuation: continuation))
                    return false
                }
                if endsNow { continuation.resume() }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else {
                    state.cancelled.insert(id)
                    return nil
                }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume()
        }
        try Task.checkCancellation()
    }

    var sleeperCount: Int {
        state.withLock { $0.sleepers.count }
    }

    /// Ends every sleep, moving time on by the longest.
    func wakeAll() {
        let sleepers = state.withLock { state in
            let sleepers = state.sleepers
            state.now += sleepers.map(\.seconds).max() ?? 0
            state.sleepers = []
            return sleepers
        }
        for sleeper in sleepers { sleeper.continuation.resume() }
    }
}

@MainActor
@Suite("Analysis key presence guard")
struct AnalysisKeyPresenceGuardTransportTests {
    static let key = AnalysisKeyFixtures.key(AnalysisKeyFixtures.googleText)

    /// `segmentCount` segments; one window holds 800, the next starts 680
    /// later.
    static func request(segmentCount: Int) -> AdAnalysisRequest {
        AdAnalysisRequest(
            requestID: "guard-request",
            episodeID: "guard-episode",
            podcastID: "https://example.com/feed.xml",
            episodeTitle: nil,
            podcastTitle: nil,
            transcript: AdAnalysisTranscript(
                languageCode: "en",
                audioDuration: Double(segmentCount * 2),
                fingerprint: "guard-fingerprint",
                updatedAt: "2026-10-25T00:00:00Z",
                segmentCount: segmentCount
            ),
            segments: (0..<segmentCount).map { index in
                AnalysisSegment(
                    id: Int64(index),
                    start: Double(index * 2),
                    end: Double(index * 2 + 2),
                    text: "Part \(index) of the conversation continues here."
                )
            }
        )
    }

    static func policy(maxInFlight: Int) throws -> AdDetectionAnalysisPolicy {
        let policy = try #require(AnalysisPolicySnapshot.baked.adDetection(provider: .google))
        var settings = policy.settings
        settings.window.maxInFlight = maxInFlight
        return policy.with(settings: settings)
    }

    static func guarded(
        _ inner: any AnalysisProviderTransport,
        keys: InMemoryAnalysisProviderKeyStorage,
        observer: any AnalysisProviderSendObserver,
        removals: AnalysisKeyRemovalLog
    ) -> AnalysisKeyPresenceGuardTransport {
        AnalysisKeyPresenceGuardTransport(
            inner: inner,
            provider: .google,
            keyDigest: key.digest,
            keys: keys,
            observer: observer,
            onRemoval: { reason in removals.record(reason, runID: "guard-run") }
        )
    }

    @Test("A key removed after the first window stops the run before the next send, one window at a time")
    func removalStopsSerialRun() async throws {
        let keys = InMemoryAnalysisProviderKeyStorage(seeded: [.google: (Self.key, syncs: false)])
        let inner = CountingAdTransport { arrival in
            if arrival == 1 { try? keys.remove(provider: .google, includingSyncedCopy: true) }
        }
        let sends = AnalysisProviderSendLog()
        let removals = AnalysisKeyRemovalLog()
        let transport = Self.guarded(inner, keys: keys, observer: sends, removals: removals)
        let request = Self.request(segmentCount: 1_481)
        let policy = try Self.policy(maxInFlight: 1)
        #expect(AdWindowing.windowCount(segmentCount: 1_481, policy: policy.settings) == 3)

        let outcome = await AnalysisRunner(transport: transport, clock: StoppedAnalysisClock()).detectAds(request, policy: policy)

        guard case .failed(let failure) = outcome else {
            Issue.record("A removed key must fail the run, got \(outcome)")
            return
        }
        #expect(failure.code == .providerRejected)
        #expect(failure.windowIndex == 1)
        #expect(inner.count == 1)
        #expect(removals.reason(runID: "guard-run") == .noKey)
        #expect(sends.sends.map(\.failure) == [.keyRequired])
        #expect(sends.sends.first?.status == nil)
        #expect(AnalysisProviderFailure.resolve(outcome, sends: sends.sends) == .keyRequired)
    }

    @Test("A key removed while four windows are out lets them finish and sends nothing new")
    func removalStopsConcurrentRun() async throws {
        let keys = InMemoryAnalysisProviderKeyStorage(seeded: [.google: (Self.key, syncs: false)])
        let allOut = AsyncTestGate()
        let inner = CountingAdTransport { arrival in
            if arrival == 4 {
                try? keys.remove(provider: .google, includingSyncedCopy: true)
                await allOut.release()
            } else {
                await allOut.wait()
            }
        }
        let removals = AnalysisKeyRemovalLog()
        let transport = Self.guarded(inner, keys: keys, observer: AnalysisProviderSendLog(), removals: removals)
        let policy = try Self.policy(maxInFlight: 4)
        #expect(AdWindowing.windowCount(segmentCount: 3_521, policy: policy.settings) == 6)

        let outcome = await AnalysisRunner(transport: transport, clock: StoppedAnalysisClock())
            .detectAds(Self.request(segmentCount: 3_521), policy: policy)

        guard case .failed(let failure) = outcome else {
            Issue.record("A removed key must fail the run, got \(outcome)")
            return
        }
        #expect(failure.code == .providerRejected)
        #expect(inner.count == 4)
        #expect(removals.reason(runID: "guard-run") == .noKey)
    }

    @Test("A Keychain read that fails stops the run as unreadable")
    func readFaultStopsRun() async throws {
        let fault = KeychainReadFault()
        let keys = InMemoryAnalysisProviderKeyStorage(seeded: [.google: (Self.key, syncs: false)], fault: fault.storageFault)
        let inner = CountingAdTransport { arrival in
            if arrival == 1 { fault.set(true) }
        }
        let removals = AnalysisKeyRemovalLog()
        let transport = Self.guarded(inner, keys: keys, observer: AnalysisProviderSendLog(), removals: removals)

        let outcome = await AnalysisRunner(transport: transport, clock: StoppedAnalysisClock())
            .detectAds(Self.request(segmentCount: 1_481), policy: try Self.policy(maxInFlight: 1))

        guard case .failed = outcome else {
            Issue.record("An unreadable key must fail the run, got \(outcome)")
            return
        }
        #expect(inner.count == 1)
        #expect(removals.reason(runID: "guard-run") == .keychainUnreadable)
    }

    @Test("A key replaced mid-run stops the run too")
    func replacedKeyStopsRun() async throws {
        let keys = InMemoryAnalysisProviderKeyStorage(seeded: [.google: (Self.key, syncs: false)])
        let replacement = AnalysisKeyFixtures.key(AnalysisKeyFixtures.replacementText)
        let inner = CountingAdTransport { arrival in
            if arrival == 1 { try? keys.save(replacement, provider: .google, syncs: false) }
        }
        let removals = AnalysisKeyRemovalLog()
        let transport = Self.guarded(inner, keys: keys, observer: AnalysisProviderSendLog(), removals: removals)

        let outcome = await AnalysisRunner(transport: transport, clock: StoppedAnalysisClock())
            .detectAds(Self.request(segmentCount: 1_481), policy: try Self.policy(maxInFlight: 1))

        guard case .failed = outcome else {
            Issue.record("A replaced key must fail the run, got \(outcome)")
            return
        }
        #expect(inner.count == 1)
        #expect(removals.reason(runID: "guard-run") == .noKey)
    }

    @Test("Replies a run kept answer its resume without the key")
    func keptRepliesNeedNoKey() async throws {
        let keys = InMemoryAnalysisProviderKeyStorage(seeded: [.google: (Self.key, syncs: false)])
        let runs = AnalysisRunRecordStore(directory: AnalysisRunTestFixtures.temporaryDirectory())
        defer { try? FileManager.default.removeItem(at: runs.directory) }
        let request = Self.request(segmentCount: 1_481)
        let policy = try Self.policy(maxInFlight: 1)
        let first = CountingAdTransport()
        let firstRun = AnalysisResumingTransport(
            inner: Self.guarded(first, keys: keys, observer: AnalysisProviderSendLog(), removals: AnalysisKeyRemovalLog()),
            store: runs,
            runID: "guard-run"
        )
        guard case .adDetection = await AnalysisRunner(transport: firstRun, clock: StoppedAnalysisClock()).detectAds(request, policy: policy) else {
            Issue.record("The first attempt must complete")
            return
        }
        #expect(first.count == 3)

        try keys.remove(provider: .google, includingSyncedCopy: true)
        let resumed = CountingAdTransport()
        let removals = AnalysisKeyRemovalLog()
        let resumedRun = AnalysisResumingTransport(
            inner: Self.guarded(resumed, keys: keys, observer: AnalysisProviderSendLog(), removals: removals),
            store: runs,
            runID: "guard-run"
        )
        let outcome = await AnalysisRunner(transport: resumedRun, clock: StoppedAnalysisClock()).detectAds(request, policy: policy)

        guard case .adDetection = outcome else {
            Issue.record("Kept replies must answer the resume, got \(outcome)")
            return
        }
        #expect(resumed.count == 0)
        #expect(removals.reason(runID: "guard-run") == nil)
    }

    @Test("The factory guards direct runs and reports a run's removal by its id")
    func factoryReportsRemovalByRunID() async throws {
        let stack = AnalysisTransportFactoryTests.Stack()
        try stack.keys.remove(provider: .google, includingSyncedCopy: true)
        let resolution = AnalysisTransportFactoryTests.direct(.google, key: AnalysisTransportFactoryTests.googleKey)
        let transport = try stack.make(resolution, runID: "factory-removed")

        let outcome = await AnalysisRunner(transport: transport, clock: StoppedAnalysisClock())
            .detectAds(AnalysisRunTestFixtures.request(), policy: try #require(resolution.policy?.adDetection))

        guard case .failed = outcome else {
            Issue.record("A removed key must fail the run, got \(outcome)")
            return
        }
        #expect(stack.client.sent.isEmpty)
        #expect(stack.factory.keyRemoval(runID: "factory-removed") == .noKey)
        #expect(stack.factory.keyRemoval(runID: "another-run") == nil)
    }

    // MARK: Keys that change while a send waits for its pacer

    /// The app's transports over a counting key store and a scripted
    /// provider; only the pacer's waits run on `pacingClock`.
    @MainActor
    final class PacedStack {
        let keys: CountingKeyStorage
        let client: ScriptedProviderHTTPClient
        let policy: AnalysisPolicySnapshotStore
        let runs = AnalysisRunRecordStore(directory: AnalysisRunTestFixtures.temporaryDirectory())
        let factory: AnalysisTransportFactory
        let sends = AnalysisProviderSendLog()

        init(pacingClock: any AnalysisClock = AnalysisSystemClock(), responses: [AnalysisHTTPResponse] = []) {
            keys = CountingKeyStorage(InMemoryAnalysisProviderKeyStorage(seeded: [.google: (AnalysisKeyPresenceGuardTransportTests.key, syncs: false)]))
            client = ScriptedProviderHTTPClient(responses)
            policy = AnalysisPolicySnapshotStore(loader: nil, pacing: AnalysisKeyPacing(clock: pacingClock), initial: .baked)
            factory = AnalysisTransportFactory(policy: policy, runs: runs, keys: keys, client: client)
        }

        deinit {
            try? FileManager.default.removeItem(at: runs.directory)
        }

        /// The key's pacer, created here with `maxInFlight` before any run
        /// creates it.
        func pacer(maxInFlight: Int) -> AnalysisKeyPacer {
            policy.pacing.pacer(provider: .google, key: AnalysisKeyPresenceGuardTransportTests.key, maxInFlight: maxInFlight)
        }

        func transport(_ feature: AnalysisFeature) throws -> (any AnalysisProviderTransport, AnalysisRouteResolution) {
            let resolution = AnalysisRouteResolution(
                feature: feature,
                route: .direct(provider: .google),
                policy: AnalysisRouteResolver.directPolicy(feature: feature, provider: .google, snapshot: .baked),
                key: AnalysisKeyPresenceGuardTransportTests.key,
                resumingRunID: nil,
                trialExchange: nil
            )
            return (try factory.makeTransport(for: resolution, runID: "paced-run", observer: sends), resolution)
        }
    }

    /// Cancels `run` and waits for it to end, so a test that stops early
    /// leaves nothing waiting.
    static func stop(_ run: Task<AnalysisOutcome, Never>) async {
        run.cancel()
        _ = await run.value
    }

    /// Changes the key while `run` waits; a change that fails stops the run
    /// before the error reaches the test.
    static func change(
        _ keys: InMemoryAnalysisProviderKeyStorage,
        during run: Task<AnalysisOutcome, Never>,
        _ change: (InMemoryAnalysisProviderKeyStorage) throws -> Void
    ) async throws {
        do {
            try change(keys)
        } catch {
            await stop(run)
            throw error
        }
    }

    /// Holds the key's only pacer slot, starts an ad-detection run whose
    /// first `queued` windows pass the guard and queue for the slot, changes
    /// the key while they wait, then frees the slot. A run that never queues
    /// is cancelled and the test fails.
    func adRunChangingKeyWhilePaced(
        maxInFlight: Int,
        segmentCount: Int,
        queued: Int,
        change: (InMemoryAnalysisProviderKeyStorage) throws -> Void
    ) async throws -> (AnalysisOutcome, PacedStack) {
        let stack = PacedStack()
        let pacer = stack.pacer(maxInFlight: 1)
        let held = await pacer.admit(deadline: stack.policy.pacing.clock.now() + 600)
        let holdsSlot = if case .admitted = held { true } else { false }
        try #require(holdsSlot, "The test must hold the pacer's only slot")
        let (transport, _) = try stack.transport(.adDetection)
        let request = Self.request(segmentCount: segmentCount)
        let policy = try Self.policy(maxInFlight: maxInFlight)
        let run = Task { await AnalysisRunner(transport: transport, clock: StoppedAnalysisClock()).detectAds(request, policy: policy) }

        // Each queued window has passed the guard's check before pacing.
        let windowsQueued = await waitUntil { stack.keys.reads == queued }
        if !windowsQueued { await Self.stop(run) }
        try #require(windowsQueued, "The run's windows must queue for the held pacer slot")
        try await Self.change(stack.keys.inner, during: run, change)
        await pacer.release()
        return (await run.value, stack)
    }

    @Test("A key removed while a window waits for its pacer is never sent, one window at a time")
    func removalWhilePacedSerial() async throws {
        let (outcome, stack) = try await adRunChangingKeyWhilePaced(maxInFlight: 1, segmentCount: 1_481, queued: 1) { keys in
            try keys.remove(provider: .google, includingSyncedCopy: true)
        }

        guard case .failed(let failure) = outcome else {
            Issue.record("A removed key must fail the run, got \(outcome)")
            return
        }
        #expect(failure.code == .providerRejected)
        #expect(failure.windowIndex == 0)
        #expect(stack.client.sentCount == 0)
        #expect(stack.factory.keyRemoval(runID: "paced-run") == .noKey)
        #expect(stack.sends.sends.map(\.failure) == [.keyRequired])
        #expect(stack.sends.sends.first?.status == nil)
        #expect(AnalysisProviderFailure.resolve(outcome, sends: stack.sends.sends) == .keyRequired)
    }

    @Test("A key removed while four windows wait for the pacer sends none of them")
    func removalWhilePacedConcurrent() async throws {
        let (outcome, stack) = try await adRunChangingKeyWhilePaced(maxInFlight: 4, segmentCount: 3_521, queued: 4) { keys in
            try keys.remove(provider: .google, includingSyncedCopy: true)
        }

        guard case .failed(let failure) = outcome else {
            Issue.record("A removed key must fail the run, got \(outcome)")
            return
        }
        #expect(failure.code == .providerRejected)
        #expect(stack.client.sentCount == 0)
        #expect(stack.factory.keyRemoval(runID: "paced-run") == .noKey)
        #expect(stack.sends.sends.contains { $0.failure == .keyRequired })
        #expect(stack.sends.sends.allSatisfy { $0.status == nil })
        #expect(AnalysisProviderFailure.resolve(outcome, sends: stack.sends.sends) == .keyRequired)
    }

    @Test("A key replaced while a window waits for its pacer is never sent")
    func replacementWhilePaced() async throws {
        let replacement = AnalysisKeyFixtures.key(AnalysisKeyFixtures.replacementText)
        let (outcome, stack) = try await adRunChangingKeyWhilePaced(maxInFlight: 1, segmentCount: 1_481, queued: 1) { keys in
            try keys.save(replacement, provider: .google, syncs: false)
        }

        guard case .failed = outcome else {
            Issue.record("A replaced key must fail the run, got \(outcome)")
            return
        }
        #expect(stack.client.sentCount == 0)
        #expect(stack.factory.keyRemoval(runID: "paced-run") == .noKey)
        #expect(AnalysisProviderFailure.resolve(outcome, sends: stack.sends.sends) == .keyRequired)
    }

    /// A short Chapters & Summary request.
    static func chaptersRequest() -> TranscriptAnalysisRequest {
        let segments: [AnalysisSegment] = (0..<40).map { (index: Int) -> AnalysisSegment in
            let start = Double(index) * 30
            let text = "Part \(index) of the conversation covers the next topic in some detail."
            return AnalysisSegment(id: Int64(index), start: start, end: start + 30, text: text)
        }
        return TranscriptAnalysisRequest(
            requestID: "guard-chapters",
            episodeID: "guard-episode",
            podcastID: "https://example.com/feed.xml",
            episodeTitle: nil,
            podcastTitle: nil,
            transcript: TranscriptAnalysisTranscript(
                languageCode: "en",
                audioDuration: 1_200,
                fingerprint: "guard-fingerprint",
                updatedAt: "2026-10-25T00:00:00Z",
                segmentCount: segments.count
            ),
            segments: segments
        )
    }

    @Test("A key removed or replaced while a Chapters retry waits out its rate limit stops the retry unsent", arguments: [false, true])
    func chaptersRetryWhilePaced(replaces: Bool) async throws {
        let clock = GatedPacingClock()
        let rateLimited = AnalysisHTTPResponse(
            status: 429,
            retryAfter: "5",
            body: Data(#"{"error":{"code":429,"message":"slow down","status":"RESOURCE_EXHAUSTED"}}"#.utf8)
        )
        let stack = PacedStack(pacingClock: clock, responses: [rateLimited])
        let (transport, resolution) = try stack.transport(.chaptersSummary)
        let policy = try #require(resolution.policy?.chaptersSummary)
        let request = Self.chaptersRequest()
        let run = Task { await AnalysisRunner(transport: transport, clock: StoppedAnalysisClock()).generateChapters(request, policy: policy) }

        // The first attempt was checked twice (before pacing and after
        // admission), sent and rate limited; its retry passed the guard and
        // waits out the cooldown in the pacer. A retry that never gets there
        // is cancelled and the test fails.
        let retryPaced = await waitUntil { clock.sleeperCount == 1 }
        if !retryPaced { await Self.stop(run) }
        try #require(retryPaced, "The retry must wait out its cooldown in the pacer")
        #expect(stack.client.sentCount == 1)
        #expect(stack.keys.reads == 3)
        let replacement = AnalysisKeyFixtures.key(AnalysisKeyFixtures.replacementText)
        try await Self.change(stack.keys.inner, during: run) { keys in
            if replaces {
                try keys.save(replacement, provider: .google, syncs: false)
            } else {
                try keys.remove(provider: .google, includingSyncedCopy: true)
            }
        }
        clock.wakeAll()
        let outcome = await run.value

        guard case .failed(let failure) = outcome else {
            Issue.record("A changed key must fail the retry, got \(outcome)")
            return
        }
        #expect(failure.code == .providerRejected)
        #expect(stack.client.sentCount == 1)
        #expect(stack.factory.keyRemoval(runID: "paced-run") == .noKey)
        #expect(stack.sends.sends.map(\.failure) == [.rateLimited, .keyRequired])
        #expect(AnalysisProviderFailure.resolve(outcome, sends: stack.sends.sends) == .keyRequired)
    }
}
