import Foundation
import Synchronization
import Testing
@testable import OpenCast

nonisolated final class DeregistrationTestLatch: Sendable {
    private struct State {
        var open = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let open = state.withLock { state in
                if state.open { return true }
                state.waiters.append(continuation)
                return false
            }
            if open { continuation.resume() }
        }
    }

    func release() {
        let waiters = state.withLock { state in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

nonisolated struct DeregistrationTestAttestService: AppAttestServiceProtocol {
    let isSupported = true
    var attestationEntered: DeregistrationTestLatch?
    var attestationRelease: DeregistrationTestLatch?
    var assertionEntered: DeregistrationTestLatch?
    var assertionRelease: DeregistrationTestLatch?
    var assertionError: (any Error)?

    func generateKey() async throws -> String { "fresh-key" }
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        attestationEntered?.release()
        await attestationRelease?.wait()
        return Data("attestation".utf8)
    }
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        assertionEntered?.release()
        await assertionRelease?.wait()
        if let assertionError { throw assertionError }
        return Data(UUID().uuidString.utf8)
    }
}

nonisolated final class DeregistrationTestTransport: AppAttestHTTPTransport, Sendable {
    struct Reply: Sendable {
        let status: Int
        let body: String
        static let deleted = Reply(status: 200, body: #"{"message":"deleted"}"#)
        static let unknownKey = Reply(status: 401, body: #"{"error":"unknown_key"}"#)
    }
    private struct State {
        var replies: [Reply]
        var requests: [URLRequest] = []
    }
    private let state: Mutex<State>
    let entered = DeregistrationTestLatch()
    let finished = DeregistrationTestLatch()
    let release: DeregistrationTestLatch?

    init(replies: [Reply] = [.deleted], release: DeregistrationTestLatch? = nil) {
        state = Mutex(State(replies: replies))
        self.release = release
    }

    var requests: [URLRequest] { state.withLock { $0.requests } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let reply = state.withLock { state in
            state.requests.append(request)
            switch request.url?.path {
            case "/v1/app-attest/challenge":
                return Reply(status: 200, body: #"{"challenge_id":"challenge","challenge":"value"}"#)
            case "/v1/app-attest/register":
                return Reply(status: 200, body: #"{"message":"registered"}"#)
            default:
                return state.replies.isEmpty ? .deleted : state.replies.removeFirst()
            }
        }
        entered.release()
        await release?.wait()
        defer { finished.release() }
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: reply.status, httpVersion: nil, headerFields: nil
        ))
        return (Data(reply.body.utf8), response)
    }
}

nonisolated struct DeregistrationTestSlot: Sendable {
    let keychain = AppAttestKeychain(service: "deregistration-tests-\(UUID().uuidString)")
    let suspension = AppAttestSuspension()
    let transport: DeregistrationTestTransport
    let attest: DeregistrationTestAttestService

    init(
        transport: DeregistrationTestTransport = .init(),
        attest: DeregistrationTestAttestService = .init()
    ) {
        self.transport = transport
        self.attest = attest
    }

    var api: AppAttestAPIClient {
        AppAttestAPIClient(
            configuration: .init(baseURL: URL(string: "https://worker.example")!, keychainService: keychain.service),
            transport: transport
        )
    }
    var credentials: AppAttestCredentialService {
        .init(appAttestService: attest, apiClient: api, keychain: keychain, suspension: suspension)
    }
    var secure: AppAttestSecureAPIClient {
        .init(apiClient: api, appAttestService: attest, assertionGate: .init(suspension: suspension))
    }
    func registerLocally() throws -> String {
        let installID = try keychain.loadOrCreateInstallID()
        try keychain.saveAppAttestKeyID("old-key")
        return installID
    }
}
