import DeviceCheck
import Foundation
import OpenCastAnalysisProviders
import Synchronization
import Testing
@testable import OpenCast

@Suite("App Attest trial exchange")
struct AppAttestTrialProxyExchangeTests {
    static let baseURL = URL(string: "https://trial-deployment.example")!
    static let analyzePath = "/v1/trial/analyze"
    static let payload = #"{"feature":"ad_detection","request":{"note":"a/b ü"},"run_id":"run-1","timeout_seconds":90,"window_index":0}"#

    /// A Keychain slot of its own for one test. Key ids are unique per
    /// test too: the assertion gate is process-wide per key id.
    struct Slot {
        let service = "opencast-trial-exchange-tests-\(UUID().uuidString)"
        let seededKeyID = "seeded-key-\(UUID().uuidString)"
        var keychain: AppAttestKeychain { AppAttestKeychain(service: service) }

        /// Registers a key in the slot, as an earlier post would have.
        func seed() throws -> (installID: String, keyID: String) {
            let installID = try keychain.loadOrCreateInstallID()
            try keychain.saveAppAttestKeyID(seededKeyID)
            return (installID, seededKeyID)
        }

        func remove() {
            try? keychain.deleteAll()
        }
    }

    func exchange(
        _ slot: Slot,
        transport: TrialRoutingTransport,
        assertions: TrialAssertionService
    ) -> AppAttestTrialProxyExchange {
        AppAttestTrialProxyExchange(
            baseURL: Self.baseURL,
            keychainService: slot.service,
            transport: transport,
            appAttestService: assertions
        )
    }

    func result(
        _ exchange: AppAttestTrialProxyExchange,
        payload: String = AppAttestTrialProxyExchangeTests.payload,
        timeout: Double = 30,
        maximum: Int = 512 * 1024
    ) async -> Result<AnalysisHTTPResponse, AnalysisHTTPFailure> {
        do {
            return .success(try await exchange.post(
                path: Self.analyzePath,
                payloadText: payload,
                timeoutSeconds: timeout,
                maximumBodyBytes: maximum
            ))
        } catch {
            return .failure(error)
        }
    }

    @Test("Each post carries a fresh assertion bound to the bare path and the payload text exactly")
    func freshAssertionPerPost() async throws {
        let slot = Slot()
        defer { slot.remove() }
        let credential = try slot.seed()
        let events = TrialEventLog()
        let assertions = TrialAssertionService(events: events)
        let transport = TrialRoutingTransport(events: events)
        let exchange = exchange(slot, transport: transport, assertions: assertions)
        let second = #"{"feature":"chapters_summary","request":{"x":"https://example.com/"},"run_id":"run-2","timeout_seconds":5,"window_index":0}"#

        _ = try await exchange.post(path: Self.analyzePath, payloadText: Self.payload, timeoutSeconds: 75, maximumBodyBytes: 1_000)
        _ = try await exchange.post(path: Self.analyzePath, payloadText: second, timeoutSeconds: 75, maximumBodyBytes: 1_000)

        #expect(transport.urls == [Self.baseURL.appending(path: Self.analyzePath), Self.baseURL.appending(path: Self.analyzePath)])
        let envelopes = transport.envelopes
        #expect(envelopes.map(\.payload) == [Self.payload, second])
        #expect(envelopes.map(\.installID) == [credential.installID, credential.installID])
        #expect(envelopes.map(\.keyID) == [credential.keyID, credential.keyID])
        #expect(envelopes.map(\.assertion) == [Data("assertion-1".utf8).base64EncodedString(), Data("assertion-2".utf8).base64EncodedString()])
        #expect(assertions.issued.map(\.keyID) == [credential.keyID, credential.keyID])
        #expect(assertions.issued.map(\.clientDataHash) == [
            AppAttestRequestBinding.clientDataHash(method: "POST", path: Self.analyzePath, payload: Self.payload),
            AppAttestRequestBinding.clientDataHash(method: "POST", path: Self.analyzePath, payload: second),
        ])
        #expect(transport.timeouts == [75, 75])
    }

    @Test("An empty slot registers on the deployment's challenge and register routes before the first post")
    func registersOnTheDeployment() async throws {
        let slot = Slot()
        defer { slot.remove() }
        let events = TrialEventLog()
        let assertions = TrialAssertionService(events: events)
        let transport = TrialRoutingTransport(events: events)

        let response = try await exchange(slot, transport: transport, assertions: assertions)
            .post(path: Self.analyzePath, payloadText: Self.payload, timeoutSeconds: 30, maximumBodyBytes: 1_000)

        #expect(response.status == 200)
        #expect(transport.paths == ["/v1/app-attest/challenge", "/v1/app-attest/register", Self.analyzePath])
        #expect(transport.urls.allSatisfy { $0.host == Self.baseURL.host })
        #expect(transport.envelopes.map(\.keyID) == [assertions.generatedKeyID(1)])
        #expect(try slot.keychain.loadAppAttestKeyID() == assertions.generatedKeyID(1))
        #expect(try slot.keychain.loadInstallID() == transport.envelopes.first?.installID)
    }

    @Test("The key's gate is held until the reply is read: a second post on the same key waits for it")
    func gateHeldThroughTheBodyRead() async throws {
        let slot = Slot()
        defer { slot.remove() }
        _ = try slot.seed()
        let events = TrialEventLog()
        let assertions = TrialAssertionService(events: events)
        let transport = TrialRoutingTransport(events: events, parksFirstPost: true)
        let exchange = exchange(slot, transport: transport, assertions: assertions)

        let first = Task { try await exchange.post(path: Self.analyzePath, payloadText: Self.payload, timeoutSeconds: 30, maximumBodyBytes: 1_000) }
        for await tag in transport.arrivals where tag == 1 {
            break
        }
        let second = Task { try await exchange.post(path: Self.analyzePath, payloadText: Self.payload, timeoutSeconds: 30, maximumBodyBytes: 1_000) }
        // Long enough for an ungated second post to issue its assertion.
        try await Task.sleep(for: .milliseconds(300))
        #expect(assertions.issued.count == 1)

        transport.releaseParked()
        _ = try await first.value
        _ = try await second.value
        #expect(events.snapshot == [.issued(1), .arrived(1), .responded(1), .issued(2), .arrived(2), .responded(2)])
    }

    @Test("A stale counter is sent again once inside the gate with a fresh assertion")
    func staleCounterRetriedOnce() async throws {
        let slot = Slot()
        defer { slot.remove() }
        let credential = try slot.seed()
        let events = TrialEventLog()
        let assertions = TrialAssertionService(events: events)
        let transport = TrialRoutingTransport(events: events, script: [
            .respond(401, body: #"{"error":"invalid_counter"}"#),
            .respond(200, body: "{\"candidates\":[]}"),
        ])

        let response = try await exchange(slot, transport: transport, assertions: assertions)
            .post(path: Self.analyzePath, payloadText: Self.payload, timeoutSeconds: 30, maximumBodyBytes: 1_000)

        #expect(response.status == 200)
        #expect(transport.paths == [Self.analyzePath, Self.analyzePath])
        #expect(transport.envelopes.map(\.keyID) == [credential.keyID, credential.keyID])
        #expect(Set(transport.envelopes.map(\.assertion)).count == 2)
        #expect(try slot.keychain.loadAppAttestKeyID() == credential.keyID)
    }

    @Test("A second stale counter registers a new key once, outside the gate, then sends on it")
    func secondStaleCounterRegistersOnce() async throws {
        let slot = Slot()
        defer { slot.remove() }
        let credential = try slot.seed()
        let events = TrialEventLog()
        let assertions = TrialAssertionService(events: events)
        let transport = TrialRoutingTransport(events: events, script: [
            .respond(401, body: #"{"error":"invalid_counter"}"#),
            .respond(401, body: #"{"error":"invalid_counter"}"#),
            .respond(200, body: "{}"),
        ])

        let response = try await exchange(slot, transport: transport, assertions: assertions)
            .post(path: Self.analyzePath, payloadText: Self.payload, timeoutSeconds: 30, maximumBodyBytes: 1_000)

        #expect(response.status == 200)
        #expect(transport.paths == [
            Self.analyzePath, Self.analyzePath, "/v1/app-attest/challenge", "/v1/app-attest/register", Self.analyzePath,
        ])
        #expect(transport.envelopes.map(\.keyID) == [credential.keyID, credential.keyID, assertions.generatedKeyID(1)])
    }

    @Test("An unknown key registers a new key once and the post goes again on it")
    func unknownKeyRegistersOnce() async throws {
        let slot = Slot()
        defer { slot.remove() }
        let credential = try slot.seed()
        let events = TrialEventLog()
        let assertions = TrialAssertionService(events: events)
        let transport = TrialRoutingTransport(events: events, script: [
            .respond(401, body: #"{"error":"unknown_key"}"#),
            .respond(200, body: "{}"),
        ])

        let response = try await exchange(slot, transport: transport, assertions: assertions)
            .post(path: Self.analyzePath, payloadText: Self.payload, timeoutSeconds: 30, maximumBodyBytes: 1_000)

        #expect(response.status == 200)
        #expect(transport.paths == [Self.analyzePath, "/v1/app-attest/challenge", "/v1/app-attest/register", Self.analyzePath])
        #expect(transport.envelopes.map(\.keyID) == [credential.keyID, assertions.generatedKeyID(1)])
        #expect(transport.envelopes.map(\.installID) == [credential.installID, credential.installID])
        #expect(try slot.keychain.loadAppAttestKeyID() == assertions.generatedKeyID(1))
    }

    @Test("A rejection recovery cannot clear comes back as the service's reply, after one registration")
    func unclearedRejectionIsTheReply() async throws {
        let slot = Slot()
        defer { slot.remove() }
        _ = try slot.seed()
        let events = TrialEventLog()
        let rejection = #"{"error":"unknown_key"}"#
        let transport = TrialRoutingTransport(events: events, script: [
            .respond(401, body: rejection),
            .respond(401, body: rejection),
        ])

        let response = try await exchange(slot, transport: transport, assertions: TrialAssertionService(events: events))
            .post(path: Self.analyzePath, payloadText: Self.payload, timeoutSeconds: 30, maximumBodyBytes: 1_000)

        #expect(response.status == 401)
        #expect(response.body == Data(rejection.utf8))
        #expect(transport.paths.count { $0 == "/v1/app-attest/register" } == 1)
        #expect(transport.paths.count { $0 == Self.analyzePath } == 2)

        // A registration that fails after the rejection also leaves the
        // rejection as the reply.
        let failingSlot = Slot()
        defer { failingSlot.remove() }
        _ = try failingSlot.seed()
        let failing = TrialRoutingTransport(events: events, script: [.respond(401, body: rejection)], challengeStatus: 503)
        let reply = try await exchange(failingSlot, transport: failing, assertions: TrialAssertionService(events: events))
            .post(path: Self.analyzePath, payloadText: Self.payload, timeoutSeconds: 30, maximumBodyBytes: 1_000)
        #expect(reply.status == 401)
        #expect(failing.paths == [Self.analyzePath, "/v1/app-attest/challenge"])
    }

    @Test("Every status comes back raw with its parsed headers, never thrown, after one post", arguments: [
        (500, #"{"error":{"code":500,"message":"internal"}}"#, nil as String?),
        (409, #"{"error":"trial_busy","retry_after_seconds":3}"#, "3"),
        (403, #"{"error":"trial_exhausted"}"#, nil),
        (401, #"{"error":"unauthorized"}"#, nil),
        (503, "<html>unavailable</html>", "7"),
    ])
    func statusesComeBackRaw(status: Int, body: String, retryAfter: String?) async throws {
        let slot = Slot()
        defer { slot.remove() }
        _ = try slot.seed()
        let events = TrialEventLog()
        var headers = ["Content-Type": "application/json; charset=utf-8"]
        if let retryAfter { headers["Retry-After"] = retryAfter }
        let transport = TrialRoutingTransport(events: events, script: [.respond(status, headers: headers, body: body)])

        let response = try await exchange(slot, transport: transport, assertions: TrialAssertionService(events: events))
            .post(path: Self.analyzePath, payloadText: Self.payload, timeoutSeconds: 30, maximumBodyBytes: 1_000)

        #expect(response.status == status)
        #expect(response.body == Data(body.utf8))
        #expect(response.retryAfterSeconds == retryAfter.flatMap(Int.init))
        #expect(response.contentType == "application/json")
        #expect(transport.paths == [Self.analyzePath])
    }

    @Test("A reply past the cap fails as oversized; one at the cap comes back")
    func capEnforced() async throws {
        let slot = Slot()
        defer { slot.remove() }
        _ = try slot.seed()
        let events = TrialEventLog()
        let atCap = String(repeating: "a", count: 64)
        let transport = TrialRoutingTransport(events: events, script: [
            .respond(200, body: atCap + "b"),
            .respond(200, body: atCap),
        ])
        let exchange = exchange(slot, transport: transport, assertions: TrialAssertionService(events: events))

        #expect(await result(exchange, maximum: 64) == .failure(.oversizedBody))
        #expect(try await exchange.post(path: Self.analyzePath, payloadText: Self.payload, timeoutSeconds: 30, maximumBodyBytes: 64).body == Data(atCap.utf8))
    }

    @Test("URLSession reads the body only up to the cap, stops the load there, and never follows a redirect")
    func urlSessionCappedRead() async throws {
        let session = URLSessionAnalysisHTTPClient.makeSession(protocolClasses: [TrialStubURLProtocol.self])
        let small = URL(string: "https://capped-small.example/v1/trial/analyze")!
        let large = URL(string: "https://capped-large.example/v1/trial/analyze")!
        let moved = URL(string: "https://capped-moved.example/v1/trial/analyze")!
        TrialStubURLProtocol.behaviors.withLock {
            $0["capped-small.example"] = .respond(status: 200, body: Data(repeating: 0x61, count: 100))
            // Past the cap, with no length announced and no end of file: a
            // reader that waits for the whole body never returns.
            $0["capped-large.example"] = .streamUnfinished(status: 200, chunks: [Data(repeating: 0x61, count: 60), Data(repeating: 0x62, count: 90)])
            $0["capped-moved.example"] = .redirect(to: URL(string: "https://elsewhere.example/")!)
        }

        let (body, response) = try await session.data(for: URLRequest(url: small), maximumBodyBytes: 100)
        #expect(body.count == 100)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        let oversized = Task { try await session.data(for: URLRequest(url: large), maximumBodyBytes: 100) }
        // Backstop so a reader that buffers to end of file fails instead of
        // hanging the suite.
        let backstop = Task {
            try? await Task.sleep(for: .seconds(10))
            oversized.cancel()
        }
        await #expect(throws: AppAttestHTTPError.responseTooLarge) {
            _ = try await oversized.value
        }
        backstop.cancel()
        // The load was stopped (cancelled) while its body was still open.
        for _ in 0..<500 where !TrialStubURLProtocol.isStopped("capped-large.example") {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(TrialStubURLProtocol.isStopped("capped-large.example"))
        #expect(!TrialStubURLProtocol.isFinished("capped-large.example"))

        let (_, redirect) = try await session.data(for: URLRequest(url: moved), maximumBodyBytes: 100)
        #expect((redirect as? HTTPURLResponse)?.statusCode == 302)
        #expect(TrialStubURLProtocol.hosts.withLock { $0.contains("elsewhere.example") } == false)
    }

    @Test("The deadline bounds the whole post, signing included, even when signing ignores cancellation")
    func deadlineBoundsSigning() async throws {
        let slot = Slot()
        defer { slot.remove() }
        _ = try slot.seed()
        let events = TrialEventLog()
        let latch = TrialLatch()
        let assertions = TrialAssertionService(events: events, parkUntil: latch)
        let transport = TrialRoutingTransport(events: events)
        let exchange = exchange(slot, transport: transport, assertions: assertions)

        let started = ContinuousClock.now
        #expect(await result(exchange, timeout: 0.3) == .failure(.timeout))
        #expect(ContinuousClock.now - started < .seconds(5))
        latch.open()

        for timeout in [0, -1, Double.nan] {
            #expect(await result(exchange, timeout: timeout) == .failure(.timeout))
        }
    }

    @Test("The deadline bounds a reply that never arrives")
    func deadlineBoundsTheReply() async throws {
        let slot = Slot()
        defer { slot.remove() }
        _ = try slot.seed()
        let events = TrialEventLog()
        let transport = TrialRoutingTransport(events: events, script: [.hang])

        let started = ContinuousClock.now
        let outcome = await result(exchange(slot, transport: transport, assertions: TrialAssertionService(events: events)), timeout: 0.3)
        #expect(outcome == .failure(.timeout))
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("Transport, DeviceCheck, registration and support failures are timeout or network and carry nothing of the post")
    func failuresCarryNothing() async throws {
        let slot = Slot()
        defer { slot.remove() }
        let credential = try slot.seed()
        let events = TrialEventLog()
        var outcomes: [(Result<AnalysisHTTPResponse, AnalysisHTTPFailure>, AnalysisHTTPFailure)] = []

        let timedOut = TrialRoutingTransport(events: events, script: [.fail(.timedOut)])
        outcomes.append((await result(exchange(slot, transport: timedOut, assertions: TrialAssertionService(events: events))), .timeout))
        let offline = TrialRoutingTransport(events: events, script: [.fail(.notConnectedToInternet)])
        outcomes.append((await result(exchange(slot, transport: offline, assertions: TrialAssertionService(events: events))), .network))
        let deviceCheck = TrialAssertionService(events: events, failure: DCError(.serverUnavailable))
        outcomes.append((await result(exchange(slot, transport: TrialRoutingTransport(events: events), assertions: deviceCheck)), .network))
        let unsupported = TrialRoutingTransport(events: events)
        outcomes.append((await result(exchange(slot, transport: unsupported, assertions: TrialAssertionService(events: events, isSupported: false))), .network))
        #expect(unsupported.paths.isEmpty)

        let emptySlot = Slot()
        defer { emptySlot.remove() }
        let unregistered = TrialRoutingTransport(events: events, challengeStatus: 503)
        outcomes.append((await result(exchange(emptySlot, transport: unregistered, assertions: TrialAssertionService(events: events))), .network))
        #expect(unregistered.paths == ["/v1/app-attest/challenge"])

        for (outcome, expected) in outcomes {
            #expect(outcome == .failure(expected))
            guard case .failure(let failure) = outcome else { continue }
            for text in [String(describing: failure), String(reflecting: failure)] {
                #expect(!text.contains(credential.installID))
                #expect(!text.contains(credential.keyID))
                #expect(!text.contains("run-1"))
                #expect(!text.contains("assertion"))
            }
        }
    }

    @Test("The raw reply shows only its status and size")
    func rawReplyRedacted() {
        let reply = AppAttestRawHTTPResponse(statusCode: 401, retryAfter: nil, contentType: nil, body: Data(#"{"error":"unknown_key","echo":"transcript"}"#.utf8))
        #expect(reply.recoverableCredentialFailure == AppAttestHTTPError(statusCode: 401, code: "unknown_key", detail: nil))
        #expect(!reply.isCounterRaceFailure)
        for text in [String(describing: reply), String(reflecting: reply), "\(Mirror(reflecting: reply).children.map(\.value))"] {
            #expect(!text.contains("transcript"))
        }
        #expect(AppAttestRawHTTPResponse(statusCode: 200, retryAfter: nil, contentType: nil, body: Data(#"{"error":"invalid_counter"}"#.utf8)).errorCode == nil)
        #expect(AppAttestRawHTTPResponse(statusCode: 401, retryAfter: nil, contentType: nil, body: Data(#"{"error":{"code":401}}"#.utf8)).recoverableCredentialFailure == nil)
    }
}

// MARK: - Fakes

nonisolated enum TrialSendEvent: Equatable, Sendable {
    case issued(Int)
    case arrived(Int)
    case responded(Int)
}

nonisolated final class TrialEventLog: Sendable {
    private let events = Mutex<[TrialSendEvent]>([])

    func append(_ event: TrialSendEvent) {
        events.withLock { $0.append(event) }
    }

    var snapshot: [TrialSendEvent] {
        events.withLock { $0 }
    }
}

/// Opens once; every waiter, earlier or later, then proceeds. Waiting does
/// not stop for cancellation.
nonisolated final class TrialLatch: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { continuation in
            let proceed = state.withLock { state in
                if state.open { return true }
                state.waiters.append(continuation)
                return false
            }
            if proceed { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// Issues assertions tagged with an increasing counter, as DeviceCheck's
/// issuance-ordered counter, and records what each one signed.
nonisolated final class TrialAssertionService: AppAttestServiceProtocol {
    struct Issued: Sendable, Equatable {
        var keyID: String
        var clientDataHash: Data
    }

    let isSupported: Bool
    private let keyPrefix = "generated-key-\(UUID().uuidString)"
    private let events: TrialEventLog
    private let failure: DCError?
    private let latch: TrialLatch?
    private let state = Mutex<(assertions: Int, keys: Int, issued: [Issued])>((0, 0, []))

    init(events: TrialEventLog, isSupported: Bool = true, failure: DCError? = nil, parkUntil latch: TrialLatch? = nil) {
        self.events = events
        self.isSupported = isSupported
        self.failure = failure
        self.latch = latch
    }

    var issued: [Issued] {
        state.withLock { $0.issued }
    }

    /// The id of the `index`th key this service generated, from 1.
    func generatedKeyID(_ index: Int) -> String {
        "\(keyPrefix)-\(index)"
    }

    func generateKey() async throws -> String {
        let index = state.withLock { state in
            state.keys += 1
            return state.keys
        }
        return generatedKeyID(index)
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        Data("attestation-\(keyID)".utf8)
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        await latch?.wait()
        if let failure { throw failure }
        let tag = state.withLock { state in
            state.assertions += 1
            state.issued.append(Issued(keyID: keyID, clientDataHash: clientDataHash))
            return state.assertions
        }
        events.append(.issued(tag))
        return Data("assertion-\(tag)".utf8)
    }
}

nonisolated struct TrialCapturedEnvelope: Decodable, Sendable, Equatable {
    let installID: String
    let keyID: String
    let payload: String
    let assertion: String?

    enum CodingKeys: String, CodingKey {
        case installID = "install_id"
        case keyID = "key_id"
        case payload
        case assertion
    }
}

/// Answers the deployment's challenge and register routes, and every other post
/// from its script (200 `{}` once the script runs out), recording each
/// request. Reads whole bodies, so the cap is the protocol's default check.
nonisolated final class TrialRoutingTransport: AppAttestHTTPTransport {
    enum Step: Sendable {
        case respond(Int, headers: [String: String] = [:], body: String)
        case fail(URLError.Code)
        case hang
    }

    private struct State {
        var script: [Step]
        var urls: [URL] = []
        var envelopes: [TrialCapturedEnvelope] = []
        var timeouts: [TimeInterval] = []
        var released = false
    }

    let arrivals: AsyncStream<Int>
    private let arrivalContinuation: AsyncStream<Int>.Continuation
    private let events: TrialEventLog
    private let parksFirstPost: Bool
    private let challengeStatus: Int
    private let state: Mutex<State>

    init(events: TrialEventLog, script: [Step] = [], parksFirstPost: Bool = false, challengeStatus: Int = 200) {
        self.events = events
        self.parksFirstPost = parksFirstPost
        self.challengeStatus = challengeStatus
        state = Mutex(State(script: script))
        (arrivals, arrivalContinuation) = AsyncStream.makeStream()
    }

    var urls: [URL] { state.withLock { $0.urls } }
    var paths: [String] { urls.map(\.path) }
    var envelopes: [TrialCapturedEnvelope] { state.withLock { $0.envelopes } }
    var timeouts: [TimeInterval] { state.withLock { $0.timeouts } }

    func releaseParked() {
        state.withLock { $0.released = true }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        state.withLock { $0.urls.append(url) }
        switch url.path {
        case "/v1/app-attest/challenge":
            return Self.response(url, challengeStatus, [:], challengeStatus == 200 ? #"{"challenge_id":"challenge-1","challenge":"nonce"}"# : #"{"error":"unavailable"}"#)
        case "/v1/app-attest/register":
            return Self.response(url, 200, [:], #"{"message":"registered"}"#)
        default:
            break
        }
        let envelope = try JSONDecoder().decode(TrialCapturedEnvelope.self, from: request.httpBody ?? Data())
        let tag = envelope.assertion
            .flatMap { Data(base64Encoded: $0) }
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap { Int($0.replacing("assertion-", with: "")) } ?? 0
        let (step, isFirst) = state.withLock { state -> (Step?, Bool) in
            state.envelopes.append(envelope)
            state.timeouts.append(request.timeoutInterval)
            return (state.script.isEmpty ? nil : state.script.removeFirst(), state.envelopes.count == 1)
        }
        events.append(.arrived(tag))
        arrivalContinuation.yield(tag)
        if parksFirstPost, isFirst {
            while !state.withLock({ $0.released }) {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { events.append(.responded(tag)) }
        switch step {
        case .respond(let status, let headers, let body)?:
            return Self.response(url, status, headers, body)
        case .fail(let code)?:
            throw URLError(code)
        case .hang?:
            try await Task.sleep(for: .seconds(3_600))
            throw URLError(.timedOut)
        case nil:
            return Self.response(url, 200, ["Content-Type": "application/json"], "{}")
        }
    }

    private static func response(_ url: URL, _ status: Int, _ headers: [String: String], _ body: String) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
}

/// Serves canned replies by host for the URLSession capped read.
nonisolated final class TrialStubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Behavior: Sendable {
        case respond(status: Int, body: Data)
        /// Sends the chunks with no Content-Length and never finishes.
        case streamUnfinished(status: Int, chunks: [Data])
        case redirect(to: URL)
    }

    static let behaviors = Mutex<[String: Behavior]>([:])
    static let hosts = Mutex<Set<String>>([])
    private static let stopped = Mutex<Set<String>>([])
    private static let finished = Mutex<Set<String>>([])

    static func isStopped(_ host: String) -> Bool {
        stopped.withLock { $0.contains(host) }
    }

    static func isFinished(_ host: String) -> Bool {
        finished.withLock { $0.contains(host) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        Self.hosts.withLock { _ = $0.insert(host) }
        switch Self.behaviors.withLock({ $0[host] }) {
        case .respond(let status, let body)?:
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            Self.finished.withLock { _ = $0.insert(host) }
            client?.urlProtocolDidFinishLoading(self)
        case .streamUnfinished(let status, let chunks)?:
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks {
                client?.urlProtocol(self, didLoad: chunk)
            }
        case .redirect(let target)?:
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
        }
    }

    override func stopLoading() {
        guard let host = request.url?.host else { return }
        Self.stopped.withLock { _ = $0.insert(host) }
    }
}
