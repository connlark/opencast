import DeviceCheck
import Foundation

/// Reads Chapters & Summary jobs the analysis service accepted before this
/// build ran the analysis on the device. Nothing here submits work: a server
/// job is only ever polled to completion.
nonisolated struct URLSessionEpisodeTranscriptAnalysisClient: EpisodeTranscriptAnalysisClient {
    static let pollTimeout: TimeInterval = 30

    let configuration: TranscriptAnalysisBackendConfiguration
    let transport: any EpisodeTranscriptAnalysisHTTPTransport
    private let appAttestService: any AppAttestServiceProtocol
    private let appAttestCredentialService: AppAttestCredentialService?
    private let appAttestSecureClient: AppAttestSecureAPIClient?

    init(
        configuration: TranscriptAnalysisBackendConfiguration = .current,
        transport: any EpisodeTranscriptAnalysisHTTPTransport & AppAttestHTTPTransport = URLSession.shared,
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
