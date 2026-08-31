import DeviceCheck
import Foundation

nonisolated struct URLSessionEpisodeTranscriptAnalysisClient: EpisodeTranscriptAnalysisClient {
    private static let analyzePath = "/v1/transcript-analysis/transcript"
    private static let bootstrapPath = "/v1/transcript-analysis/account/bootstrap"

    /// Async-capable submits return promptly (202, or a cached completed
    /// result); the generous ceiling covers App Attest handshakes and large
    /// cached-result bodies, not model time.
    static let analyzeTimeout: TimeInterval = 90
    static let pollTimeout: TimeInterval = 30
    static let bootstrapTimeout: TimeInterval = 30

    let configuration: TranscriptAnalysisBackendConfiguration
    let transport: any EpisodeTranscriptAnalysisHTTPTransport
    private let appAttestService: any AppAttestServiceProtocol
    private let appAttestCredentialService: AppAttestCredentialService?
    private let appAttestSecureClient: AppAttestSecureAPIClient?
    private let appTransactionJWSProvider: @Sendable () async -> String?

    init(
        configuration: TranscriptAnalysisBackendConfiguration = .current,
        transport: any EpisodeTranscriptAnalysisHTTPTransport & AppAttestHTTPTransport = URLSession.shared,
        appAttestService: any AppAttestServiceProtocol = DeviceCheckAppAttestService.shared,
        appTransactionJWSProvider: @escaping @Sendable () async -> String? = {
            (try? await RemoteTranscriptionAppTransactionProvider.currentJWS()) ?? nil
        }
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

    func analyze(_ requestBody: EpisodeTranscriptAnalysisAPIRequest) async throws -> EpisodeTranscriptAnalysisSubmitOutcome {
        guard configuration.isEnabled else {
            throw EpisodeTranscriptAnalysisError.clientDisabled
        }

        #if DEBUG
        if Self.forcesCapRejection(
            environment: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments
        ) {
            throw EpisodeTranscriptAnalysisHTTPError(
                statusCode: 429,
                code: "daily_request_cap_exceeded",
                detail: "Forced by OPENCAST_TRANSCRIPT_ANALYSIS_FORCE_CAP"
            )
        }
        #endif

        let outcome = switch configuration.authentication {
        #if DEBUG
        case .bearer(let clientToken):
            try await sendWithBearer(
                path: Self.analyzePath,
                payload: requestBody,
                timeout: Self.analyzeTimeout,
                clientToken: clientToken,
                response: EpisodeTranscriptAnalysisSubmitOutcome.self
            )
        #endif
        case .appAttest:
            try await sendWithAppAttest(
                path: Self.analyzePath,
                payload: requestBody,
                timeout: Self.analyzeTimeout,
                response: EpisodeTranscriptAnalysisSubmitOutcome.self
            )
        }

        if case .accepted(let jobID, _) = outcome,
           jobID != requestBody.transcript.fingerprint
        {
            throw EpisodeTranscriptAnalysisHTTPError(
                statusCode: -1,
                code: "job_id_mismatch",
                detail: nil
            )
        }
        return outcome
    }

    func pollJob(id: String) async throws -> EpisodeTranscriptAnalysisJobPollOutcome {
        guard configuration.isEnabled else {
            throw EpisodeTranscriptAnalysisError.clientDisabled
        }

        let path = Self.jobPath(id)
        let requestBody = EpisodeTranscriptAnalysisJobPollRequest(jobID: id)
        return switch configuration.authentication {
        #if DEBUG
        case .bearer(let clientToken):
            try await sendWithBearer(
                path: path,
                payload: requestBody,
                timeout: Self.pollTimeout,
                clientToken: clientToken,
                response: EpisodeTranscriptAnalysisJobPollOutcome.self
            )
        #endif
        case .appAttest:
            try await sendWithAppAttest(
                path: path,
                payload: requestBody,
                timeout: Self.pollTimeout,
                response: EpisodeTranscriptAnalysisJobPollOutcome.self
            )
        }
    }

    func bootstrapAccount() async throws {
        guard configuration.isEnabled else {
            throw EpisodeTranscriptAnalysisError.clientDisabled
        }

        switch configuration.authentication {
        #if DEBUG
        case .bearer:
            // The bearer probe lane is billing-exempt and has no install
            // identity; the worker serves bootstrap only inside an App
            // Attest envelope.
            throw EpisodeTranscriptAnalysisError.appAttestUnavailable
        #endif
        case .appAttest:
            let requestBody = EpisodeTranscriptAnalysisAPIBootstrapRequest(
                schemaVersion: EpisodeTranscriptAnalysisContract.schemaVersion,
                appTransactionJWS: await appTransactionJWSProvider()
            )
            _ = try await sendWithAppAttest(
                path: Self.bootstrapPath,
                payload: requestBody,
                timeout: Self.bootstrapTimeout,
                response: EpisodeTranscriptAnalysisAPIBootstrapResponse.self
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
        request.httpBody = try EpisodeTranscriptAnalysisJSONCoding.encoder().encode(payload)

        let (data, urlResponse) = try await transport.data(for: request)
        return try decodeResponse(data: data, urlResponse: urlResponse, response: response)
    }
    #endif

    private func sendWithAppAttest<Payload: Encodable & Sendable, Response: Decodable & Sendable>(
        path: String,
        payload requestBody: Payload,
        timeout: TimeInterval,
        response: Response.Type
    ) async throws -> Response {
        guard appAttestService.isSupported else {
            throw EpisodeTranscriptAnalysisError.appAttestUnavailable
        }
        guard let appAttestCredentialService,
              let appAttestSecureClient
        else {
            throw EpisodeTranscriptAnalysisError.appAttestUnavailable
        }

        do {
            return try await appAttestCredentialService.withFreshCredentialOnRecoverableFailure { credential in
                let payload = try EpisodeTranscriptAnalysisJSONCoding.canonicalPayloadString(requestBody)
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
            throw EpisodeTranscriptAnalysisHTTPError(
                statusCode: error.statusCode,
                code: error.code,
                detail: error.detail
            )
        }
    }

    #if DEBUG
    /// The documented way to reproduce cap-deferral states without spending
    /// real worker requests. Environment variable or launch argument.
    static func forcesCapRejection(environment: [String: String], arguments: [String]) -> Bool {
        environment["OPENCAST_TRANSCRIPT_ANALYSIS_FORCE_CAP"] == "1"
            || arguments.contains("-OPENCAST_TRANSCRIPT_ANALYSIS_FORCE_CAP")
    }
    #endif

    private static func jobPath(_ id: String) -> String {
        "/v1/transcript-analysis/jobs/\(id)"
    }

    private func decodeResponse<Response: Decodable>(
        data: Data,
        urlResponse: URLResponse,
        response: Response.Type
    ) throws -> Response {
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw EpisodeTranscriptAnalysisHTTPError(statusCode: -1, code: "invalid_response", detail: nil)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorResponse = try? EpisodeTranscriptAnalysisJSONCoding.decoder()
                .decode(EpisodeTranscriptAnalysisAPIErrorResponse.self, from: data)
            throw EpisodeTranscriptAnalysisHTTPError(
                statusCode: httpResponse.statusCode,
                code: errorResponse?.error ?? "http_\(httpResponse.statusCode)",
                detail: errorResponse?.detail
            )
        }

        return try EpisodeTranscriptAnalysisJSONCoding.decoder().decode(response, from: data)
    }
}
