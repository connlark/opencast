import Foundation
import OpenCastAnalysisProviders
import Synchronization

/// Posts to the trial service with the install's App Attest key for the
/// service's deployment: each post carries a fresh assertion over
/// `POST\n<path>\n<sha256 of the payload>`, the key's assertion gate is
/// held until the whole reply is read, a stale counter is retried once and
/// an unknown key is registered again once, and the reply is capped. The
/// deployment's slot holds its own install id and key, registered with
/// that deployment's `/v1/app-attest/challenge` and `/register`. Every
/// status comes back as the service sent it; only a post that got no reply
/// fails. Nothing here logs.
nonisolated struct AppAttestTrialProxyExchange: AnalysisTrialProxyExchange {
    /// One session for every trial exchange: nothing cached, no cookies, no
    /// stored credentials.
    static let session = URLSessionAnalysisHTTPClient.makeSession()

    let baseURL: URL
    let keychainService: String
    private let appAttestService: any AppAttestServiceProtocol
    private let credentials: AppAttestCredentialService
    private let client: AppAttestSecureAPIClient

    init(
        baseURL: URL,
        keychainService: String,
        transport: any AppAttestHTTPTransport = AppAttestTrialProxyExchange.session,
        appAttestService: any AppAttestServiceProtocol = DeviceCheckAppAttestService.shared
    ) {
        self.baseURL = baseURL
        self.keychainService = keychainService
        self.appAttestService = appAttestService
        let apiClient = AppAttestAPIClient(
            configuration: AppAttestClientConfiguration(baseURL: baseURL, keychainService: keychainService),
            transport: transport
        )
        credentials = AppAttestCredentialService(
            appAttestService: appAttestService,
            apiClient: apiClient,
            keychain: AppAttestKeychain(service: keychainService)
        )
        client = AppAttestSecureAPIClient(apiClient: apiClient, appAttestService: appAttestService)
    }

    func post(
        path: String,
        payloadText: String,
        timeoutSeconds: Double,
        maximumBodyBytes: Int
    ) async throws(AnalysisHTTPFailure) -> AnalysisHTTPResponse {
        let limit = AnalysisProviderLimits.waitSeconds(timeoutSeconds)
        guard limit > 0 else { throw .timeout }
        guard appAttestService.isSupported else { throw .network }
        let reply: AppAttestRawHTTPResponse
        do {
            reply = try await TrialProxyDeadline.run(seconds: limit) { [self] in
                try await exchange(path: path, payloadText: payloadText, timeoutSeconds: limit, maximumBodyBytes: maximumBodyBytes)
            }
        } catch {
            throw Self.failure(for: error)
        }
        return AnalysisHTTPResponse(
            status: reply.statusCode,
            retryAfter: reply.retryAfter,
            contentType: reply.contentType,
            body: reply.body
        )
    }

    /// One post with the credential recovery around it: a rejection a new
    /// key could clear deletes the key and registers a new one once,
    /// outside the gate. When recovery does not clear it, the service's
    /// last rejection goes back as the reply.
    private func exchange(
        path: String,
        payloadText: String,
        timeoutSeconds: Double,
        maximumBodyBytes: Int
    ) async throws -> AppAttestRawHTTPResponse {
        let lastRejection = LastRejection()
        do {
            return try await credentials.withFreshCredentialOnRecoverableFailure { credential in
                let reply = try await client.sendRawPayloadForRawResponse(
                    path: path,
                    installID: credential.installID,
                    keyID: credential.keyID,
                    payload: payloadText,
                    timeout: timeoutSeconds,
                    maximumBodyBytes: maximumBodyBytes
                )
                if let failure = reply.recoverableCredentialFailure {
                    lastRejection.set(reply)
                    throw failure
                }
                return reply
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if !Task.isCancelled, let reply = lastRejection.reply {
                return reply
            }
            throw error
        }
    }

    /// The deadline is `.timeout`, as is a transport timeout; a body past
    /// the cap is `.oversizedBody`; every other failure (transport,
    /// Keychain, DeviceCheck, registration, cancellation) is `.network`.
    static func failure(for error: any Error) -> AnalysisHTTPFailure {
        switch error {
        case let failure as AnalysisHTTPFailure:
            failure
        case let error as URLError where error.code == .timedOut:
            .timeout
        case let error as AppAttestHTTPError where error == .responseTooLarge:
            .oversizedBody
        default:
            .network
        }
    }
}

/// The latest reply a post's credential recovery saw rejected.
private nonisolated final class LastRejection: Sendable {
    private let storage = Mutex<AppAttestRawHTTPResponse?>(nil)

    var reply: AppAttestRawHTTPResponse? {
        storage.withLock { $0 }
    }

    func set(_ reply: AppAttestRawHTTPResponse) {
        storage.withLock { $0 = reply }
    }
}
