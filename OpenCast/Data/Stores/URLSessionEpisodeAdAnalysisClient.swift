import DeviceCheck
import Foundation

nonisolated struct URLSessionEpisodeAdAnalysisClient: EpisodeAdAnalysisClient {
    private static let analyzePath = "/v1/ad-analysis/transcript"

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

    func analyze(_ requestBody: EpisodeAdAnalysisAPIRequest) async throws -> EpisodeAdAnalysisAPIResponse {
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

        switch configuration.authentication {
        #if DEBUG
        case .bearer(let clientToken):
            return try await analyzeWithBearer(requestBody, clientToken: clientToken)
        #endif
        case .appAttest:
            return try await analyzeWithAppAttest(requestBody)
        }
    }

    #if DEBUG
    private func analyzeWithBearer(
        _ requestBody: EpisodeAdAnalysisAPIRequest,
        clientToken: String
    ) async throws -> EpisodeAdAnalysisAPIResponse {
        var request = URLRequest(url: configuration.workerBaseURL.appending(path: Self.analyzePath))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(clientToken)", forHTTPHeaderField: "authorization")
        request.httpBody = try EpisodeAdAnalysisJSONCoding.encoder().encode(requestBody)

        let (data, urlResponse) = try await transport.data(for: request)
        return try decodeResponse(data: data, urlResponse: urlResponse)
    }
    #endif

    private func analyzeWithAppAttest(
        _ requestBody: EpisodeAdAnalysisAPIRequest
    ) async throws -> EpisodeAdAnalysisAPIResponse {
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
                    path: Self.analyzePath,
                    installID: credential.installID,
                    keyID: credential.keyID,
                    payload: payload,
                    response: EpisodeAdAnalysisAPIResponse.self
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

    private func decodeResponse(data: Data, urlResponse: URLResponse) throws -> EpisodeAdAnalysisAPIResponse {
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

        return try EpisodeAdAnalysisJSONCoding.decoder().decode(
            EpisodeAdAnalysisAPIResponse.self,
            from: data
        )
    }
}
