import DeviceCheck
import Foundation

nonisolated struct URLSessionEpisodeAdAnalysisClient: EpisodeAdAnalysisClient {
    private static let analyzePath = "/v1/ad-analysis/transcript"

    /// Single-window requests remain synchronous. Multi-window requests return
    /// a job promptly, so this only needs to cover one model call plus retries.
    static let analyzeTimeout: TimeInterval = 90
    static let pollTimeout: TimeInterval = 30

    let configuration: AdAnalysisBackendConfiguration
    let transport: any EpisodeAdAnalysisHTTPTransport
    private let appAttestService: any AppAttestServiceProtocol
    private let appAttestCredentialService: AppAttestCredentialService?
    private let appAttestSecureClient: AppAttestSecureAPIClient?

    init(
        configuration: AdAnalysisBackendConfiguration = .current,
        transport: any EpisodeAdAnalysisHTTPTransport & AppAttestHTTPTransport = URLSession.shared,
        appAttestService: any AppAttestServiceProtocol = DeviceCheckAppAttestService.shared
    ) {
        self.configuration = configuration
        self.transport = transport
        self.appAttestService = appAttestService
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

    func analyze(_ requestBody: EpisodeAdAnalysisAPIRequest) async throws -> EpisodeAdAnalysisSubmitOutcome {
        guard configuration.isEnabled else {
            throw EpisodeAdAnalysisError.clientDisabled
        }

        #if DEBUG
        if Self.forcesCapRejection(
            environment: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments
        ) {
            throw EpisodeAdAnalysisHTTPError(
                statusCode: 429,
                code: "daily_request_cap_exceeded",
                detail: "Forced by OPENCAST_ADANALYSIS_FORCE_CAP"
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
                response: EpisodeAdAnalysisSubmitOutcome.self
            )
        #endif
        case .appAttest:
            try await sendWithAppAttest(
                path: Self.analyzePath,
                payload: requestBody,
                timeout: Self.analyzeTimeout,
                response: EpisodeAdAnalysisSubmitOutcome.self
            )
        }

        if case .accepted(let jobID, _) = outcome,
           jobID != requestBody.transcript.fingerprint
        {
            throw EpisodeAdAnalysisHTTPError(
                statusCode: -1,
                code: "job_id_mismatch",
                detail: nil
            )
        }
        return outcome
    }

    func pollJob(id: String) async throws -> EpisodeAdAnalysisJobPollOutcome {
        guard configuration.isEnabled else {
            throw EpisodeAdAnalysisError.clientDisabled
        }

        let path = Self.jobPath(id)
        let requestBody = EpisodeAdAnalysisJobPollRequest(jobID: id)
        return switch configuration.authentication {
        #if DEBUG
        case .bearer(let clientToken):
            try await sendWithBearer(
                path: path,
                payload: requestBody,
                timeout: Self.pollTimeout,
                clientToken: clientToken,
                response: EpisodeAdAnalysisJobPollOutcome.self
            )
        #endif
        case .appAttest:
            try await sendWithAppAttest(
                path: path,
                payload: requestBody,
                timeout: Self.pollTimeout,
                response: EpisodeAdAnalysisJobPollOutcome.self
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
        request.httpBody = try EpisodeAdAnalysisJSONCoding.encoder().encode(payload)

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
            throw EpisodeAdAnalysisError.appAttestUnavailable
        }
        guard let appAttestCredentialService,
              let appAttestSecureClient
        else {
            throw EpisodeAdAnalysisError.appAttestUnavailable
        }

        do {
            return try await appAttestCredentialService.withFreshCredentialOnRecoverableFailure { credential in
                let payload = try EpisodeAdAnalysisJSONCoding.canonicalPayloadString(requestBody)
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
            throw EpisodeAdAnalysisHTTPError(
                statusCode: error.statusCode,
                code: error.code,
                detail: error.detail
            )
        }
    }

    #if DEBUG
    /// The documented way to reproduce cap states without spending real
    /// worker requests (decision 10). Environment variable or launch argument.
    static func forcesCapRejection(environment: [String: String], arguments: [String]) -> Bool {
        environment["OPENCAST_ADANALYSIS_FORCE_CAP"] == "1"
            || arguments.contains("-OPENCAST_ADANALYSIS_FORCE_CAP")
    }
    #endif

    private static func jobPath(_ id: String) -> String {
        "/v1/ad-analysis/jobs/\(id)"
    }

    private func decodeResponse<Response: Decodable>(
        data: Data,
        urlResponse: URLResponse,
        response: Response.Type
    ) throws -> Response {
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw EpisodeAdAnalysisHTTPError(statusCode: -1, code: "invalid_response", detail: nil)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorResponse = try? EpisodeAdAnalysisJSONCoding.decoder()
                .decode(EpisodeAdAnalysisAPIErrorResponse.self, from: data)
            throw EpisodeAdAnalysisHTTPError(
                statusCode: httpResponse.statusCode,
                code: errorResponse?.error ?? "http_\(httpResponse.statusCode)",
                detail: errorResponse?.detail
            )
        }

        return try EpisodeAdAnalysisJSONCoding.decoder().decode(response, from: data)
    }
}
