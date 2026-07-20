import Foundation

nonisolated struct AppAttestAPIClient: Sendable {
    private static let registerPurpose = "register"

    let configuration: AppAttestClientConfiguration
    let transport: any AppAttestHTTPTransport

    init(
        configuration: AppAttestClientConfiguration,
        transport: any AppAttestHTTPTransport = URLSession.shared
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    func requestChallenge(installID: String) async throws -> AppAttestChallengeResponse {
        let body = AppAttestChallengeRequest(
            installID: installID,
            purpose: Self.registerPurpose
        )
        return try await send(
            path: configuration.challengePath,
            body: body,
            response: AppAttestChallengeResponse.self
        )
    }

    func register(
        installID: String,
        keyID: String,
        challengeID: String,
        challenge: String,
        attestationObject: Data
    ) async throws -> String {
        let body = AppAttestRegisterRequest(
            installID: installID,
            keyID: keyID,
            challengeID: challengeID,
            challenge: challenge,
            attestationObject: attestationObject.base64EncodedString()
        )
        let response = try await send(
            path: configuration.registerPath,
            body: body,
            response: AppAttestMessageResponse.self
        )
        return response.message
    }

    func sendAuthenticatedEnvelope<ResponseBody: Decodable>(
        path: String,
        installID: String,
        keyID: String,
        payload: String,
        assertion: Data?,
        timeout: TimeInterval? = nil,
        response: ResponseBody.Type
    ) async throws -> ResponseBody {
        let body = AppAttestAuthenticatedEnvelope(
            installID: installID,
            keyID: keyID,
            payload: payload,
            assertion: assertion?.base64EncodedString()
        )
        return try await send(path: path, body: body, timeout: timeout, response: response)
    }

    func send<RequestBody: Encodable, ResponseBody: Decodable>(
        path: String,
        body: RequestBody,
        timeout: TimeInterval? = nil,
        response: ResponseBody.Type
    ) async throws -> ResponseBody {
        var request = URLRequest(url: configuration.baseURL.appending(path: path))
        request.httpMethod = "POST"
        if let timeout {
            request.timeoutInterval = timeout
        }
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, urlResponse) = try await transport.data(for: request)
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw AppAttestHTTPError(statusCode: -1, code: "invalid_response", detail: nil)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorResponse = try? JSONDecoder().decode(AppAttestErrorResponse.self, from: data)
            throw AppAttestHTTPError(
                statusCode: httpResponse.statusCode,
                code: errorResponse?.error ?? "http_\(httpResponse.statusCode)",
                detail: errorResponse?.detail
            )
        }

        return try JSONDecoder().decode(response, from: data)
    }
}
