import Foundation
import Testing
@testable import OpenCast

@Suite("App Attest counter-race fix")
struct AppAttestCounterRaceTests {
    @Test("Concurrent sends on one key serialize issuance through response")
    func concurrentSendsOnOneKeySerializeIssuanceThroughResponse() async throws {
        let events = AppAttestEventLog()
        let assertions = SequencedAssertionService(events: events)
        let transport = SerializationProbeTransport(events: events)
        let client = makeSecureClient(assertions: assertions, transport: transport)
        let keyID = "serialized-key-\(UUID().uuidString)"
        let sendCount = 12

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<sendCount {
                group.addTask {
                    _ = try await client.sendRawPayload(
                        path: "/v1/secure/hello",
                        installID: "install",
                        keyID: keyID,
                        payload: "hello",
                        response: AppAttestMessageResponse.self
                    )
                }
            }
            try await group.waitForAll()
        }

        #expect(transport.maxInFlight == 1)
        // Every send must complete its issue → arrive → respond triple with
        // one counter tag before the next issuance happens; any interleave
        // is exactly the reordering window the gate exists to close.
        let recorded = events.snapshot()
        try #require(recorded.count == sendCount * 3)
        for turn in 0..<sendCount {
            let triple = Array(recorded[(turn * 3)..<(turn * 3 + 3)])
            guard case .issued(let tag) = triple[0] else {
                Issue.record("Turn \(turn) began with \(triple[0]) instead of an issuance")
                return
            }
            #expect(triple[1] == .arrived(tag))
            #expect(triple[2] == .responded(tag))
        }
    }

    @Test("Distinct keys do not wait on each other")
    func distinctKeysDoNotWaitOnEachOther() async throws {
        let parkedKeyID = "parked-key-\(UUID().uuidString)"
        let transport = ParkingTransport(parkedKeyID: parkedKeyID)
        let client = makeSecureClient(
            assertions: SequencedAssertionService(events: AppAttestEventLog()),
            transport: transport
        )

        let parkedSend = Task {
            _ = try await client.sendRawPayload(
                path: "/v1/secure/hello",
                installID: "install",
                keyID: parkedKeyID,
                payload: "hello",
                response: AppAttestMessageResponse.self
            )
        }
        for await arrivedKeyID in transport.arrivals where arrivedKeyID == parkedKeyID {
            break
        }

        // Backstop so a wrongly global gate fails assertions instead of
        // hanging the suite; on the correct path the release below wins.
        let backstop = Task {
            try? await Task.sleep(for: .seconds(30))
            transport.releaseParked()
        }
        _ = try await client.sendRawPayload(
            path: "/v1/secure/hello",
            installID: "install",
            keyID: "independent-key-\(UUID().uuidString)",
            payload: "hello",
            response: AppAttestMessageResponse.self
        )
        #expect(transport.isParked)

        transport.releaseParked()
        backstop.cancel()
        _ = try await parkedSend.value
    }

    @Test("A lost counter race retries once with a fresh assertion")
    func lostCounterRaceRetriesOnceWithFreshAssertion() async throws {
        let events = AppAttestEventLog()
        let assertions = SequencedAssertionService(events: events)
        let transport = ScriptedTransport(script: [
            (401, Data(#"{"error":"invalid_counter","detail":"stale counter"}"#.utf8)),
            (200, Data(#"{"message":"ok"}"#.utf8)),
        ])
        let client = makeSecureClient(assertions: assertions, transport: transport)

        let response = try await client.sendRawPayload(
            path: "/v1/secure/hello",
            installID: "install",
            keyID: "retry-key",
            payload: "hello",
            response: AppAttestMessageResponse.self
        )

        #expect(response.message == "ok")
        let sentAssertions = transport.capturedEnvelopeAssertions()
        try #require(sentAssertions.count == 2)
        #expect(sentAssertions[0] != sentAssertions[1])
    }

    @Test("A second counter failure propagates instead of retrying again")
    func secondCounterFailurePropagatesInsteadOfRetryingAgain() async throws {
        let transport = ScriptedTransport(script: [
            (401, Data(#"{"error":"invalid_counter","detail":"stale counter"}"#.utf8)),
            (401, Data(#"{"error":"invalid_counter","detail":"still stale"}"#.utf8)),
        ])
        let client = makeSecureClient(
            assertions: SequencedAssertionService(events: AppAttestEventLog()),
            transport: transport
        )

        await #expect(throws: AppAttestHTTPError(
            statusCode: 401,
            code: "invalid_counter",
            detail: "still stale"
        )) {
            _ = try await client.sendRawPayload(
                path: "/v1/secure/hello",
                installID: "install",
                keyID: "retry-key",
                payload: "hello",
                response: AppAttestMessageResponse.self
            )
        }
        #expect(transport.capturedEnvelopeAssertions().count == 2)
    }

    @Test("Other credential failures do not consume the counter retry")
    func otherCredentialFailuresDoNotConsumeCounterRetry() async throws {
        let transport = ScriptedTransport(script: [
            (401, Data(#"{"error":"unknown_key","detail":"no such key"}"#.utf8)),
        ])
        let client = makeSecureClient(
            assertions: SequencedAssertionService(events: AppAttestEventLog()),
            transport: transport
        )

        await #expect(throws: AppAttestHTTPError(
            statusCode: 401,
            code: "unknown_key",
            detail: "no such key"
        )) {
            _ = try await client.sendRawPayload(
                path: "/v1/secure/hello",
                installID: "install",
                keyID: "unknown-key",
                payload: "hello",
                response: AppAttestMessageResponse.self
            )
        }
        #expect(transport.capturedEnvelopeAssertions().count == 1)
    }

    @MainActor
    @Test("syncIfRegistered recovers a recoverable failure like sync does")
    func syncIfRegisteredRecoversRecoverableFailureLikeSync() async throws {
        let keychain = AppAttestKeychain(service: "opencast-counter-race-tests-\(UUID().uuidString)")
        defer { try? keychain.deleteAll() }
        _ = try keychain.loadOrCreateInstallID()
        try keychain.saveAppAttestKeyID("stale-key")

        let transport = SubscriptionSyncRoutingTransport(firstSyncStatus: 401)
        let service = makeSyncService(keychain: keychain, transport: transport)

        let response = try await service.syncIfRegistered(
            activePodcastIDs: ["https://example.com/feed.xml"]
        )

        #expect(response?.message == "synced")
        #expect(transport.requestPaths().contains("/v1/app-attest/challenge"))
        #expect(transport.requestPaths().contains("/v1/app-attest/register"))
        #expect(transport.requestPaths().filter { $0 == "/v1/subscriptions/sync" }.count == 2)
        #expect(try keychain.loadAppAttestKeyID() == "fresh-key")
    }

    @MainActor
    @Test("syncIfRegistered still sends nothing for an unregistered install")
    func syncIfRegisteredStillSendsNothingForUnregisteredInstall() async throws {
        let keychain = AppAttestKeychain(service: "opencast-counter-race-tests-\(UUID().uuidString)")
        defer { try? keychain.deleteAll() }

        let transport = SubscriptionSyncRoutingTransport(firstSyncStatus: 200)
        let service = makeSyncService(keychain: keychain, transport: transport)

        let response = try await service.syncIfRegistered(
            activePodcastIDs: ["https://example.com/feed.xml"]
        )

        #expect(response == nil)
        #expect(transport.requestPaths().isEmpty)
    }

    private func makeSecureClient(
        assertions: SequencedAssertionService,
        transport: any AppAttestHTTPTransport
    ) -> AppAttestSecureAPIClient {
        AppAttestSecureAPIClient(
            apiClient: AppAttestAPIClient(
                configuration: AppAttestClientConfiguration(
                    baseURL: URL(string: "https://worker.example")!,
                    keychainService: "unused"
                ),
                transport: transport
            ),
            appAttestService: assertions
        )
    }

    @MainActor
    private func makeSyncService(
        keychain: AppAttestKeychain,
        transport: SubscriptionSyncRoutingTransport
    ) -> NotificationSubscriptionSyncService {
        let apiClient = NotificationSecurityAPIClient(
            baseURL: URL(string: "https://worker.example")!,
            transport: transport
        )
        let registrations = RegisteringAppAttestService()
        return NotificationSubscriptionSyncService(
            credentialService: NotificationSecurityCredentialService(
                appAttestService: registrations,
                apiClient: apiClient,
                keychain: keychain
            ),
            secureClient: NotificationSecureAPIClient(
                apiClient: apiClient,
                appAttestService: registrations
            )
        )
    }
}

private enum AppAttestSendEvent: Equatable {
    case issued(Int)
    case arrived(Int)
    case responded(Int)
}

private nonisolated final class AppAttestEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AppAttestSendEvent] = []

    func append(_ event: AppAttestSendEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [AppAttestSendEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

/// Issues assertions tagged with a strictly increasing counter, mirroring
/// `DCAppAttestService`'s issuance-ordered counter.
private nonisolated final class SequencedAssertionService: AppAttestServiceProtocol, @unchecked Sendable {
    let isSupported = true
    private let lock = NSLock()
    private let events: AppAttestEventLog
    private var counter = 0

    init(events: AppAttestEventLog) {
        self.events = events
    }

    func generateKey() async throws -> String {
        "generated-key"
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        Data("attestation-\(keyID)".utf8)
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        let tag = nextTag()
        events.append(.issued(tag))
        // Widen the window between issuance and arrival so an ungated
        // client would interleave here.
        await Task.yield()
        await Task.yield()
        return Data("assertion-\(tag)".utf8)
    }

    private func nextTag() -> Int {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        return counter
    }
}

private nonisolated final class SerializationProbeTransport: AppAttestHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let events: AppAttestEventLog
    private var inFlight = 0
    private(set) var maxInFlight = 0

    init(events: AppAttestEventLog) {
        self.events = events
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let tag = try Self.assertionTag(in: request)
        enterInFlight()
        events.append(.arrived(tag))
        await Task.yield()
        await Task.yield()
        events.append(.responded(tag))
        exitInFlight()
        return try Self.okResponse(for: request, body: Data(#"{"message":"ok"}"#.utf8))
    }

    private func enterInFlight() {
        lock.lock()
        defer { lock.unlock() }
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
    }

    private func exitInFlight() {
        lock.lock()
        defer { lock.unlock() }
        inFlight -= 1
    }

    private static func assertionTag(in request: URLRequest) throws -> Int {
        let envelope = try JSONDecoder().decode(CapturedEnvelope.self, from: request.httpBody ?? Data())
        let assertionText = String(decoding: Data(base64Encoded: envelope.assertion ?? "") ?? Data(), as: UTF8.self)
        return try #require(Int(assertionText.replacingOccurrences(of: "assertion-", with: "")))
    }

    static func okResponse(for request: URLRequest, body: Data) throws -> (Data, URLResponse) {
        let response = try #require(HTTPURLResponse(
            url: request.url ?? URL(string: "https://worker.example")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        return (body, response)
    }
}

private nonisolated final class ParkingTransport: AppAttestHTTPTransport, @unchecked Sendable {
    let arrivals: AsyncStream<String>
    private let arrivalsContinuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private let parkedKeyID: String
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var didRelease = false

    init(parkedKeyID: String) {
        self.parkedKeyID = parkedKeyID
        (arrivals, arrivalsContinuation) = AsyncStream<String>.makeStream()
    }

    var isParked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return releaseContinuation != nil
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let envelope = try JSONDecoder().decode(CapturedEnvelope.self, from: request.httpBody ?? Data())
        arrivalsContinuation.yield(envelope.keyID)
        if envelope.keyID == parkedKeyID {
            await withCheckedContinuation { continuation in
                lock.lock()
                if didRelease {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                releaseContinuation = continuation
                lock.unlock()
            }
        }
        return try SerializationProbeTransport.okResponse(
            for: request,
            body: Data(#"{"message":"ok"}"#.utf8)
        )
    }

    func releaseParked() {
        lock.lock()
        didRelease = true
        let parked = releaseContinuation
        releaseContinuation = nil
        lock.unlock()
        parked?.resume()
    }
}

private nonisolated final class ScriptedTransport: AppAttestHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [(statusCode: Int, body: Data)]
    private var envelopes: [CapturedEnvelope] = []

    init(script: [(statusCode: Int, body: Data)]) {
        self.script = script
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let envelope = try JSONDecoder().decode(CapturedEnvelope.self, from: request.httpBody ?? Data())
        let step = consumeStep(envelope: envelope)
        let response = try #require(HTTPURLResponse(
            url: request.url ?? URL(string: "https://worker.example")!,
            statusCode: step.statusCode,
            httpVersion: nil,
            headerFields: nil
        ))
        return (step.body, response)
    }

    private func consumeStep(envelope: CapturedEnvelope) -> (statusCode: Int, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        envelopes.append(envelope)
        return script.isEmpty
            ? (statusCode: 200, body: Data(#"{"message":"ok"}"#.utf8))
            : script.removeFirst()
    }

    func capturedEnvelopeAssertions() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return envelopes.compactMap(\.assertion)
    }
}

/// Routes the challenge/register/sync trio for the `syncIfRegistered`
/// parity tests: the first sync attempt fails as scripted, the re-attested
/// retry succeeds.
private nonisolated final class SubscriptionSyncRoutingTransport: AppAttestHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let firstSyncStatus: Int
    private var syncCalls = 0
    private var paths: [String] = []

    init(firstSyncStatus: Int) {
        self.firstSyncStatus = firstSyncStatus
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        let syncCall = recordArrival(path: path)

        let step: (statusCode: Int, body: Data)
        switch path {
        case "/v1/app-attest/challenge":
            step = (200, Data(#"{"challenge_id":"challenge-1","challenge":"challenge-value"}"#.utf8))
        case "/v1/app-attest/register":
            step = (200, Data(#"{"message":"registered"}"#.utf8))
        case "/v1/subscriptions/sync":
            if syncCall == 1 && firstSyncStatus != 200 {
                step = (firstSyncStatus, Data(#"{"error":"unknown_key","detail":"no such key"}"#.utf8))
            } else {
                step = (200, Data(#"{"message":"synced","accepted":[],"rejected":[],"pending":[]}"#.utf8))
            }
        default:
            step = (404, Data(#"{"error":"not_found"}"#.utf8))
        }
        let response = try #require(HTTPURLResponse(
            url: request.url ?? URL(string: "https://worker.example")!,
            statusCode: step.statusCode,
            httpVersion: nil,
            headerFields: nil
        ))
        return (step.body, response)
    }

    private func recordArrival(path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        paths.append(path)
        if path == "/v1/subscriptions/sync" {
            syncCalls += 1
        }
        return syncCalls
    }

    func requestPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }
}

private nonisolated final class RegisteringAppAttestService: AppAttestServiceProtocol, @unchecked Sendable {
    let isSupported = true

    func generateKey() async throws -> String {
        "fresh-key"
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        Data("attestation-\(keyID)".utf8)
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        Data("assertion-\(keyID)-\(UUID().uuidString)".utf8)
    }
}

private nonisolated struct CapturedEnvelope: Decodable {
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
