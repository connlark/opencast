import DeviceCheck
import Foundation
import OpenCastTranscription

/// URLSession-backed client for the remote transcription worker. Reuses the
/// existing App Attest client/envelope and key lifecycle; every dynamic job
/// path is bound exactly into the assertion. Cancellation is normal; sizes
/// and timeouts are bounded.
nonisolated struct RemoteTranscriptionAPIClient: RemoteTranscriptionAPI {
    private static let bootstrapPath = "/v1/remote-transcription/account/bootstrap"
    private static let jobsPath = "/v1/remote-transcription/jobs"
    private static let redeemPath = "/v1/remote-transcription/purchases/redeem"

    static let requestTimeout: TimeInterval = 30
    /// Result payloads carry the full transcript JSON.
    static let resultTimeout: TimeInterval = 120
    static let maxResponseBytes = 32 * 1_024 * 1_024

    let configuration: RemoteTranscriptionBackendConfiguration
    let transport: any AppAttestHTTPTransport
    private let appAttestService: any AppAttestServiceProtocol
    private let appAttestCredentialService: AppAttestCredentialService?
    private let appAttestSecureClient: AppAttestSecureAPIClient?
    /// Purchase-backend lanes attach the verified AppTransaction JWS to every
    /// bootstrap; injected so tests stay StoreKit-free.
    private let appTransactionJWSProvider: @Sendable () async throws -> String?

    init(
        configuration: RemoteTranscriptionBackendConfiguration = .current,
        transport: any AppAttestHTTPTransport = URLSession.shared,
        appAttestService: any AppAttestServiceProtocol = DeviceCheckAppAttestService.shared,
        appTransactionJWSProvider: @escaping @Sendable () async throws -> String? =
            RemoteTranscriptionAppTransactionProvider.currentJWS
    ) {
        self.configuration = configuration
        self.transport = transport
        self.appAttestService = appAttestService
        self.appTransactionJWSProvider = appTransactionJWSProvider
        switch configuration.authentication {
        #if DEBUG
        case .bearer:
            appAttestCredentialService = nil
            appAttestSecureClient = nil
        #endif
        case .appAttest(let keychainService):
            let appAttestConfiguration = AppAttestClientConfiguration(
                baseURL: configuration.workerBaseURL,
                keychainService: keychainService
            )
            let apiClient = AppAttestAPIClient(
                configuration: appAttestConfiguration,
                transport: transport
            )
            appAttestCredentialService = AppAttestCredentialService(
                appAttestService: appAttestService,
                apiClient: apiClient,
                keychain: AppAttestKeychain(service: keychainService)
            )
            appAttestSecureClient = AppAttestSecureAPIClient(
                apiClient: apiClient,
                appAttestService: appAttestService
            )
        }
    }

    func bootstrap() async throws -> OpenCastRemoteTranscriptionBootstrapResponse {
        let appTransactionJWS = configuration.requiresAppTransaction
            ? try await appTransactionJWSProvider()
            : nil
        if configuration.requiresAppTransaction, appTransactionJWS == nil {
            throw RemoteTranscriptionHTTPError(
                statusCode: -1,
                code: OpenCastRemoteTranscriptionErrorCode.invalidRequest.wireValue,
                detail: "AppTransaction unavailable"
            )
        }
        return try await send(
            path: Self.bootstrapPath,
            payload: OpenCastRemoteTranscriptionBootstrapRequest(appTransactionJWS: appTransactionJWS),
            timeout: Self.requestTimeout,
            response: OpenCastRemoteTranscriptionBootstrapResponse.self
        )
    }

    func redeem(
        transactionJWS: String
    ) async throws -> OpenCastRemoteTranscriptionRedeemResponse {
        try await send(
            path: Self.redeemPath,
            payload: OpenCastRemoteTranscriptionRedeemRequest(transactionJWS: transactionJWS),
            timeout: Self.requestTimeout,
            response: OpenCastRemoteTranscriptionRedeemResponse.self
        )
    }

    func createJob(
        _ request: OpenCastRemoteTranscriptionJobCreateRequest
    ) async throws -> OpenCastRemoteTranscriptionJobResponse {
        try await send(
            path: Self.jobsPath,
            payload: request,
            timeout: Self.requestTimeout,
            response: OpenCastRemoteTranscriptionJobResponse.self
        )
    }

    func reportSource(
        jobID: String,
        identity: OpenCastRemoteTranscriptionSourceIdentity
    ) async throws -> OpenCastRemoteTranscriptionJobResponse {
        try await send(
            path: Self.jobPath(jobID, action: "source"),
            payload: OpenCastRemoteTranscriptionSourceReportRequest(sourceIdentity: identity),
            timeout: Self.requestTimeout,
            response: OpenCastRemoteTranscriptionJobResponse.self
        )
    }

    func poll(jobID: String) async throws -> OpenCastRemoteTranscriptionPollResponse {
        try await send(
            path: Self.jobPath(jobID, action: "poll"),
            payload: OpenCastRemoteTranscriptionPollRequest(schemaVersion: OpenCastRemoteTranscriptionSchema.version),
            timeout: Self.requestTimeout,
            response: OpenCastRemoteTranscriptionPollResponse.self
        )
    }

    func uploadStart(
        jobID: String,
        forBackground: Bool
    ) async throws -> OpenCastRemoteTranscriptionUploadGrantResponse {
        try await send(
            path: Self.jobPath(jobID, action: "upload/start"),
            payload: OpenCastRemoteTranscriptionUploadStartRequest(
                forBackground: forBackground ? true : nil
            ),
            timeout: Self.requestTimeout,
            response: OpenCastRemoteTranscriptionUploadGrantResponse.self
        )
    }

    func uploadParts(
        jobID: String,
        partNumbers: [Int],
        forBackground: Bool
    ) async throws -> OpenCastRemoteTranscriptionUploadGrantResponse {
        try await send(
            path: Self.jobPath(jobID, action: "upload/parts"),
            payload: OpenCastRemoteTranscriptionUploadPartsRequest(
                partNumbers: partNumbers,
                forBackground: forBackground ? true : nil
            ),
            timeout: Self.requestTimeout,
            response: OpenCastRemoteTranscriptionUploadGrantResponse.self
        )
    }

    func uploadComplete(
        jobID: String,
        parts: [OpenCastRemoteTranscriptionUploadCompletedPart]
    ) async throws -> OpenCastRemoteTranscriptionJobResponse {
        try await send(
            path: Self.jobPath(jobID, action: "upload/complete"),
            payload: OpenCastRemoteTranscriptionUploadCompleteRequest(parts: parts),
            timeout: Self.requestTimeout,
            response: OpenCastRemoteTranscriptionJobResponse.self
        )
    }

    func result(jobID: String) async throws -> OpenCastRemoteTranscriptionResultResponse {
        try await send(
            path: Self.jobPath(jobID, action: "result"),
            payload: OpenCastRemoteTranscriptionPollRequest(schemaVersion: OpenCastRemoteTranscriptionSchema.version),
            timeout: Self.resultTimeout,
            response: OpenCastRemoteTranscriptionResultResponse.self
        )
    }

    func ack(
        jobID: String,
        normalizedTranscriptSHA256: String?
    ) async throws -> OpenCastRemoteTranscriptionJobResponse {
        try await send(
            path: Self.jobPath(jobID, action: "ack"),
            payload: OpenCastRemoteTranscriptionAckRequest(
                normalizedTranscriptSHA256: normalizedTranscriptSHA256
            ),
            timeout: Self.requestTimeout,
            response: OpenCastRemoteTranscriptionJobResponse.self
        )
    }

    func cancel(jobID: String) async throws -> OpenCastRemoteTranscriptionJobResponse {
        try await send(
            path: Self.jobPath(jobID, action: "cancel"),
            payload: OpenCastRemoteTranscriptionPollRequest(schemaVersion: OpenCastRemoteTranscriptionSchema.version),
            timeout: Self.requestTimeout,
            response: OpenCastRemoteTranscriptionJobResponse.self
        )
    }

    private static func jobPath(_ jobID: String, action: String) -> String {
        "/v1/remote-transcription/jobs/\(jobID)/\(action)"
    }

    private func send<Payload: Encodable & Sendable, Response: Decodable & Sendable>(
        path: String,
        payload: Payload,
        timeout: TimeInterval,
        response: Response.Type
    ) async throws -> Response {
        guard configuration.isEnabled else {
            throw RemoteTranscriptionHTTPError(
                statusCode: -1,
                code: OpenCastRemoteTranscriptionErrorCode.featureDisabled.wireValue,
                detail: nil
            )
        }

        switch configuration.authentication {
        #if DEBUG
        case .bearer(let clientToken):
            return try await sendWithBearer(
                path: path,
                payload: payload,
                timeout: timeout,
                clientToken: clientToken,
                response: response
            )
        #endif
        case .appAttest:
            return try await sendWithAppAttest(
                path: path,
                payload: payload,
                timeout: timeout,
                response: response
            )
        }
    }

    #if DEBUG
    private func sendWithBearer<Payload: Encodable & Sendable, Response: Decodable & Sendable>(
        path: String,
        payload: Payload,
        timeout: TimeInterval,
        clientToken: String,
        response: Response.Type
    ) async throws -> Response {
        var request = URLRequest(url: configuration.workerBaseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(clientToken)", forHTTPHeaderField: "authorization")
        request.httpBody = try RemoteTranscriptionJSONCoding.encoder().encode(payload)

        let (data, urlResponse) = try await transport.data(for: request)
        return try Self.decodeResponse(data: data, urlResponse: urlResponse, response: response)
    }
    #endif

    private func sendWithAppAttest<Payload: Encodable & Sendable, Response: Decodable & Sendable>(
        path: String,
        payload requestBody: Payload,
        timeout: TimeInterval,
        response: Response.Type
    ) async throws -> Response {
        guard appAttestService.isSupported,
              let appAttestCredentialService,
              let appAttestSecureClient
        else {
            throw RemoteTranscriptionHTTPError(
                statusCode: -1,
                code: OpenCastRemoteTranscriptionErrorCode.unauthorized.wireValue,
                detail: "App Attest unavailable"
            )
        }

        do {
            return try await appAttestCredentialService.withFreshCredentialOnRecoverableFailure { credential in
                let payload = try RemoteTranscriptionJSONCoding.canonicalPayloadString(requestBody)
                return try await appAttestSecureClient.sendRawPayload(
                    path: path,
                    installID: credential.installID,
                    keyID: credential.keyID,
                    payload: payload,
                    timeout: timeout,
                    response: response
                )
            }
        } catch let error as AppAttestHTTPError {
            throw RemoteTranscriptionHTTPError(
                statusCode: error.statusCode,
                code: error.code,
                detail: error.detail
            )
        }
    }

    static func decodeResponse<Response: Decodable>(
        data: Data,
        urlResponse: URLResponse,
        response: Response.Type
    ) throws -> Response {
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw RemoteTranscriptionHTTPError(statusCode: -1, code: "invalid_response", detail: nil)
        }
        guard data.count <= maxResponseBytes else {
            throw RemoteTranscriptionHTTPError(statusCode: -1, code: "response_too_large", detail: nil)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorResponse = try? RemoteTranscriptionJSONCoding.decoder()
                .decode(RemoteTranscriptionAPIErrorResponse.self, from: data)
            throw RemoteTranscriptionHTTPError(
                statusCode: httpResponse.statusCode,
                code: errorResponse?.error ?? "http_\(httpResponse.statusCode)",
                detail: errorResponse?.detail
            )
        }

        return try RemoteTranscriptionJSONCoding.decoder().decode(response, from: data)
    }
}
