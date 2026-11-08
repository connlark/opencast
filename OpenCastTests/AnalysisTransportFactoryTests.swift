import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import Synchronization
import Testing
@testable import OpenCast

/// Records every provider request and refuses it, so nothing reaches the
/// network.
nonisolated final class CapturingAnalysisHTTPClient: AnalysisHTTPClient {
    private let requests = Mutex<[AnalysisHTTPRequest]>([])
    private let status: Int
    private let body: String

    init(status: Int = 400, body: String = #"{"error":{"code":400,"message":"fixture refusal","status":"INVALID_ARGUMENT"}}"#) {
        self.status = status
        self.body = body
    }

    var sent: [AnalysisHTTPRequest] {
        requests.withLock { $0 }
    }

    func send(
        _ request: AnalysisHTTPRequest,
        timeoutSeconds: Double,
        maximumBodyBytes: Int
    ) async throws(AnalysisHTTPFailure) -> AnalysisHTTPResponse {
        requests.withLock { $0.append(request) }
        return AnalysisHTTPResponse(status: status, contentType: "application/json", body: Data(body.utf8))
    }
}

/// Time that passes only when something sleeps, remembering every sleep, so
/// a test reads the waits a pacer asked for.
nonisolated final class RecordingAnalysisClock: AnalysisClock {
    private let state = Mutex<(now: Double, sleeps: [Double])>((0, []))

    var sleeps: [Double] {
        state.withLock { $0.sleeps }
    }

    func now() -> Double {
        state.withLock { $0.now }
    }

    func sleep(seconds: Double) async throws {
        state.withLock { state in
            state.now += seconds
            state.sleeps.append(seconds)
        }
    }
}

@MainActor
@Suite("Analysis transport factory")
struct AnalysisTransportFactoryTests {
    static let googleKey = AnalysisKeyFixtures.key(AnalysisKeyFixtures.googleText)
    static let openAIKey = AnalysisKeyFixtures.key(AnalysisKeyFixtures.openAIText)

    /// The baked bundle with each provider's endpoint moved to another
    /// version path on its pinned host, and a version header added, so a
    /// request shows it was built from the bundle.
    static var snapshot: AnalysisPolicySnapshot {
        var bundle = AnalysisPolicyBundle.baked
        bundle.providers[.google]?.baseURL = URL(string: "https://generativelanguage.googleapis.com/v1alpha")!
        bundle.providers[.google]?.versionHeaders = ["x-fixture-version": "g7"]
        bundle.providers[.openai]?.baseURL = URL(string: "https://api.openai.com/v2")!
        bundle.providers[.openai]?.versionHeaders = ["x-fixture-version": "o7"]
        return AnalysisPolicySnapshot(bundle: bundle, source: .baked, fallbackReason: nil, lastRefreshFailure: nil)
    }

    @MainActor
    final class Stack {
        let runs = AnalysisRunRecordStore(directory: AnalysisRunTestFixtures.temporaryDirectory())
        let client: CapturingAnalysisHTTPClient
        let factory: AnalysisTransportFactory

        let keys: InMemoryAnalysisProviderKeyStorage

        init(
            snapshot: AnalysisPolicySnapshot = AnalysisTransportFactoryTests.snapshot,
            fixture: AnalysisUITestTransportMode? = nil,
            keys: InMemoryAnalysisProviderKeyStorage = InMemoryAnalysisProviderKeyStorage(seeded: [
                .google: (AnalysisTransportFactoryTests.googleKey, syncs: false),
                .openai: (AnalysisTransportFactoryTests.openAIKey, syncs: false),
            ]),
            client: CapturingAnalysisHTTPClient = CapturingAnalysisHTTPClient(),
            pacingClock: (any AnalysisClock)? = nil
        ) {
            self.keys = keys
            self.client = client
            let policy = pacingClock.map {
                AnalysisPolicySnapshotStore(loader: nil, pacing: AnalysisKeyPacing(clock: $0), initial: snapshot)
            } ?? .fixed(snapshot)
            factory = AnalysisTransportFactory(policy: policy, runs: runs, keys: keys, fixture: fixture, client: client)
        }

        deinit {
            try? FileManager.default.removeItem(at: runs.directory)
        }

        func make(_ resolution: AnalysisRouteResolution, runID: String = "factory-run") throws(AnalysisTransportFactoryError) -> any AnalysisProviderTransport {
            try factory.makeTransport(for: resolution, runID: runID, observer: runs.observer(runID: runID))
        }
    }

    static func direct(_ provider: AnalysisProvider, key: AnalysisProviderKey?, snapshot: AnalysisPolicySnapshot = snapshot) -> AnalysisRouteResolution {
        AnalysisRouteResolution(
            feature: .adDetection,
            route: .direct(provider: provider),
            policy: AnalysisRouteResolver.directPolicy(feature: .adDetection, provider: provider, snapshot: snapshot),
            key: key,
            resumingRunID: nil,
            trialExchange: nil
        )
    }

    static func trial(_ exchange: (any AnalysisTrialProxyExchange)?) -> AnalysisRouteResolution {
        AnalysisRouteResolution(
            feature: .adDetection,
            route: .trial,
            policy: AnalysisRouteResolver.trialPolicy(feature: .adDetection, snapshot: AnalysisRunTestFixtures.snapshot),
            key: nil,
            resumingRunID: nil,
            trialExchange: exchange
        )
    }

    /// The provider transport under the resume wrapper and, for a direct
    /// route, the key guard.
    static func inner(_ transport: any AnalysisProviderTransport) -> (any AnalysisProviderTransport)? {
        let resumed = (transport as? AnalysisResumingTransport)?.inner
        return (resumed as? AnalysisKeyPresenceGuardTransport)?.inner ?? resumed
    }

    @Test("A Google route builds the Gemini transport from the bundle's endpoint with the key, wrapped for resume")
    func googleDirect() async throws {
        let stack = Stack()
        let resolution = Self.direct(.google, key: Self.googleKey)
        let transport = try stack.make(resolution)

        #expect(Self.inner(transport) is GeminiAnalysisTransport)
        _ = await AnalysisRunner(transport: transport).detectAds(AnalysisRunTestFixtures.request(), policy: try #require(resolution.policy?.adDetection))

        let request = try #require(stack.client.sent.first)
        #expect(request.url.absoluteString == "https://generativelanguage.googleapis.com/v1alpha/models/gemini-3.8-flash:generateContent")
        #expect(request.header("x-goog-api-key") == AnalysisKeyFixtures.googleText)
        #expect(request.header("x-fixture-version") == "g7")
        #expect(request.header("authorization") == nil)
    }

    /// A free-tier per-minute 429 with no delay, so a retry never waits.
    private static let freeTierMinuteBody = #"{"error":{"code":429,"message":"quota","status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaId":"GenerateRequestsPerMinutePerProjectPerModel-FreeTier","quotaValue":"15"}]}]}}"#

    @Test("A resolution inside the window makes a free-tier 429 final: one send, and the run ends")
    func handoverFlagMakesAFreeTierAnswerFinal() async throws {
        let stack = Stack(client: CapturingAnalysisHTTPClient(status: 429, body: Self.freeTierMinuteBody))
        var resolution = Self.direct(.google, key: Self.googleKey)
        resolution.freeTierHandover = true
        let transport = try stack.make(resolution)

        let outcome = await AnalysisRunner(transport: transport, clock: StoppedAnalysisClock())
            .detectAds(AnalysisRunTestFixtures.request(), policy: try #require(resolution.policy?.adDetection))

        guard case .failed(let failure) = outcome else {
            Issue.record("the run did not fail: \(outcome)")
            return
        }
        #expect(failure.code == .quotaExhausted)
        #expect(stack.client.sent.count == 1)
    }

    @Test("Outside the window the same 429 is retried as before")
    func noHandoverFlagKeepsRetrying() async throws {
        let stack = Stack(client: CapturingAnalysisHTTPClient(status: 429, body: Self.freeTierMinuteBody))
        let resolution = Self.direct(.google, key: Self.googleKey)
        #expect(!resolution.freeTierHandover)
        let transport = try stack.make(resolution)

        let outcome = await AnalysisRunner(transport: transport, clock: StoppedAnalysisClock())
            .detectAds(AnalysisRunTestFixtures.request(), policy: try #require(resolution.policy?.adDetection))

        guard case .failed(let failure) = outcome else {
            Issue.record("the run did not fail: \(outcome)")
            return
        }
        #expect(failure.code != .quotaExhausted)
        #expect(stack.client.sent.count > 1)
    }

    /// Inside ad detection's 10-second backoff cap: a longer delay ends the
    /// run after one send, for any key.
    static let retryDelaySeconds = 7.0

    /// A per-minute 429 with a retry delay, named free tier or not by its id.
    static func minuteBody(quotaID: String) -> String {
        #"{"error":{"code":429,"message":"quota","status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaId":"\#(quotaID)","quotaValue":"15"}]},{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"\#(Int(retryDelaySeconds))s"}]}}"#
    }

    static let freeTierMinuteQuotaID = "GenerateRequestsPerMinutePerProjectPerModel-FreeTier"

    /// One direct run over a client that answers every send with `body`:
    /// what was sent, and every wait the key's pacer asked its clock for.
    private func pacedRun(body: String) async throws -> (sends: [AnalysisProviderSendRecord], waits: [Double]) {
        let clock = RecordingAnalysisClock()
        let stack = Stack(client: CapturingAnalysisHTTPClient(status: 429, body: body), pacingClock: clock)
        let resolution = Self.direct(.google, key: Self.googleKey)
        #expect(!resolution.freeTierHandover)
        let log = AnalysisProviderSendLog()
        let transport = try stack.factory.makeTransport(for: resolution, runID: "paced-run", observer: log)

        _ = await AnalysisRunner(transport: transport, clock: StoppedAnalysisClock())
            .detectAds(AnalysisRunTestFixtures.request(), policy: try #require(resolution.policy?.adDetection))

        return (log.sends, clock.sleeps)
    }

    @Test("Outside the window a free-tier per-minute 429 waits on the pacer exactly as a paid key's does")
    func noHandoverFlagKeepsThePace() async throws {
        let free = try await pacedRun(body: Self.minuteBody(quotaID: Self.freeTierMinuteQuotaID))
        let paid = try await pacedRun(body: Self.minuteBody(quotaID: "GenerateRequestsPerMinutePerProjectPerModel"))

        // Every send after the first waits out the delay Google named.
        #expect(free.sends.count > 1)
        #expect(free.waits == Array(repeating: Self.retryDelaySeconds, count: free.sends.count - 1))
        #expect(free.sends.map(\.pacedSeconds) == [0] + free.waits)
        #expect(free.sends.allSatisfy { $0.freeTier })

        #expect(free.waits == paid.waits)
        #expect(free.sends.map(\.pacedSeconds) == paid.sends.map(\.pacedSeconds))
        #expect(paid.sends.allSatisfy { !$0.freeTier })
    }

    @Test("A tier check goes to the bundle's endpoint with the key it was given, outside any run")
    func tierCheckUsesTheEndpoint() async throws {
        let stack = Stack(client: CapturingAnalysisHTTPClient(status: 200, body: "{}"))

        #expect(await stack.factory.checkTier(key: Self.googleKey) == .notFreeTier)

        let request = try #require(stack.client.sent.first)
        #expect(stack.client.sent.count == 1)
        #expect(request.url.absoluteString == "https://generativelanguage.googleapis.com/v1alpha/models/gemini-pro-latest:generateContent")
        #expect(request.header("x-goog-api-key") == AnalysisKeyFixtures.googleText)
    }

    @Test("A key change reads the Keychain now: the same key stands; gone or replaced does not")
    func keyChangeReadsTheKeychain() throws {
        let stack = Stack()
        #expect(stack.factory.keyChange(provider: .google, keyDigest: Self.googleKey.digest) == nil)

        try stack.keys.save(try #require(AnalysisProviderKey("replacement-test-key")), provider: .google, syncs: false)
        #expect(stack.factory.keyChange(provider: .google, keyDigest: Self.googleKey.digest) == .noKey)

        try stack.keys.remove(provider: .google, includingSyncedCopy: true)
        #expect(stack.factory.keyChange(provider: .google, keyDigest: Self.googleKey.digest) == .noKey)
    }

    @Test("An OpenAI route builds the Responses transport from the bundle's endpoint with the key, wrapped for resume")
    func openAIDirect() async throws {
        let stack = Stack()
        let resolution = Self.direct(.openai, key: Self.openAIKey)
        let transport = try stack.make(resolution)

        #expect(Self.inner(transport) is OpenAIAnalysisTransport)
        _ = await AnalysisRunner(transport: transport).detectAds(AnalysisRunTestFixtures.request(), policy: try #require(resolution.policy?.adDetection))

        let request = try #require(stack.client.sent.first)
        #expect(request.url.absoluteString == "https://api.openai.com/v2/responses")
        #expect(request.header("authorization") == "Bearer \(AnalysisKeyFixtures.openAIText)")
        #expect(request.header("x-fixture-version") == "o7")
        #expect(request.header("x-goog-api-key") == nil)
    }

    @Test("The trial route sends through the resolution's exchange under the run id, wrapped for resume")
    func trialUsesTheExchange() async throws {
        let stack = Stack()
        let exchange = RecordingTrialProxyExchange()
        let resolution = Self.trial(exchange)
        let runID = UUID().uuidString
        let transport = try stack.make(resolution, runID: runID)

        #expect(Self.inner(transport) is TrialProxyAnalysisTransport)
        let outcome = await AnalysisRunner(transport: transport).detectAds(AnalysisRunTestFixtures.request(), policy: try #require(resolution.policy?.adDetection))

        guard case .adDetection = outcome else {
            Issue.record("expected the trial run to finish, got \(outcome)")
            return
        }
        #expect(exchange.posts.map(\.windowIndex) == [0, 1, 2])
        #expect(exchange.posts.allSatisfy { $0.runID == runID })
        #expect(stack.client.sent.isEmpty)
        #expect(stack.runs.replies(runID: runID).count == AnalysisRunTestFixtures.windowCount)
    }

    @Test("A route without a way to send throws the reason", arguments: AnalysisKeyRequiredReason.allCases)
    func keyRequiredThrows(reason: AnalysisKeyRequiredReason) {
        let stack = Stack()
        #expect(throws: AnalysisTransportFactoryError.keyRequired(reason)) {
            _ = try stack.make(.keyRequired(reason, feature: .adDetection))
        }
    }

    @Test("A trial route without an exchange, or a direct route without a key, throws instead of sending")
    func missingPartsThrow() {
        let stack = Stack()
        #expect(throws: AnalysisTransportFactoryError.keyRequired(.proxyUnavailable)) {
            _ = try stack.make(Self.trial(nil))
        }
        #expect(throws: AnalysisTransportFactoryError.keyRequired(.noKey)) {
            _ = try stack.make(Self.direct(.google, key: nil))
        }
        #expect(stack.client.sent.isEmpty)
    }

    @Test("A bundle without the provider's endpoint, or with one off its pinned host, is a configuration error")
    func endpointErrors() {
        var missing = AnalysisPolicyBundle.baked
        missing.providers[.openai] = nil
        let missingSnapshot = AnalysisPolicySnapshot(bundle: missing, source: .baked, fallbackReason: nil, lastRefreshFailure: nil)
        #expect(throws: AnalysisTransportFactoryError.configuration(.unpinnedEndpoint)) {
            _ = try Stack(snapshot: missingSnapshot).make(Self.direct(.openai, key: Self.openAIKey, snapshot: missingSnapshot))
        }

        var moved = AnalysisPolicyBundle.baked
        moved.providers[.google]?.baseURL = URL(string: "https://gemini.example.com/v1beta")!
        let movedSnapshot = AnalysisPolicySnapshot(bundle: moved, source: .baked, fallbackReason: nil, lastRefreshFailure: nil)
        #expect(throws: AnalysisTransportFactoryError.configuration(.unpinnedEndpoint)) {
            _ = try Stack(snapshot: movedSnapshot).make(Self.direct(.google, key: Self.googleKey, snapshot: movedSnapshot))
        }

        var wrongAuth = AnalysisPolicyBundle.baked
        wrongAuth.providers[.google]?.auth = .bearer
        let wrongAuthSnapshot = AnalysisPolicySnapshot(bundle: wrongAuth, source: .baked, fallbackReason: nil, lastRefreshFailure: nil)
        #expect(throws: AnalysisTransportFactoryError.configuration(.wrongAuthentication)) {
            _ = try Stack(snapshot: wrongAuthSnapshot).make(Self.direct(.google, key: Self.googleKey, snapshot: wrongAuthSnapshot))
        }
    }

    @Test("UI tests answer every route from the fixture transport, wrapped for resume, with no request")
    func fixtureMode() async throws {
        let stack = Stack(fixture: AnalysisUITestTransportMode(answer: .fixture, holds: false))
        let exchange = RecordingTrialProxyExchange()

        for resolution in [Self.direct(.google, key: Self.googleKey), Self.direct(.openai, key: Self.openAIKey), Self.trial(exchange)] {
            let transport = try stack.make(resolution)
            let fixture = try #require(Self.inner(transport) as? AnalysisUITestFixtureTransport)
            #expect(fixture.route == resolution.route)
        }
        let transport = try stack.make(Self.trial(exchange))
        _ = await AnalysisRunner(transport: transport).detectAds(
            AnalysisRunTestFixtures.request(),
            policy: try #require(Self.trial(exchange).policy?.adDetection)
        )
        #expect(exchange.posts.isEmpty)
        #expect(stack.client.sent.isEmpty)

        // The fixture never stands in for the key screen.
        #expect(throws: AnalysisTransportFactoryError.keyRequired(.trialExhausted)) {
            _ = try stack.make(.keyRequired(.trialExhausted, feature: .adDetection))
        }
    }

    @Test("Send observers fan out to every observer")
    func observersFanOut() {
        let first = AnalysisProviderSendLog()
        let second = AnalysisProviderSendLog()
        let send = AnalysisProviderSendRecord(
            provider: .google, modelID: "gemini-3.8-flash", feature: .adDetection, purpose: .adWindow(index: 0),
            sendIndex: 0, status: 200, finishReason: nil, failure: nil, usage: nil, pacedSeconds: 0, exchangeSeconds: 1
        )

        AnalysisSendObservers(observers: [first, second]).record(send)

        #expect(first.sends == [send])
        #expect(second.sends == [send])
    }
}
