import Foundation

struct NotificationSecurityAPIClient {
    private static let registerPurpose = "register"

    let baseURL: URL
    let session: URLSession

    init(
        baseURL: URL = NotificationBackendConfiguration.current.workerBaseURL,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    func requestChallenge(installID: String) async throws -> NotificationSecurityChallengeResponse {
        let body = NotificationSecurityChallengeRequest(
            installID: installID,
            purpose: Self.registerPurpose
        )
        return try await send(
            path: "/v1/app-attest/challenge",
            body: body,
            response: NotificationSecurityChallengeResponse.self
        )
    }

    func register(
        installID: String,
        keyID: String,
        challengeID: String,
        challenge: String,
        attestationObject: Data
    ) async throws -> String {
        let body = NotificationSecurityRegisterRequest(
            installID: installID,
            keyID: keyID,
            challengeID: challengeID,
            challenge: challenge,
            attestationObject: attestationObject.base64EncodedString()
        )
        let response = try await send(
            path: "/v1/app-attest/register",
            body: body,
            response: NotificationSecurityMessageResponse.self
        )
        return response.message
    }

    func secureHello(
        installID: String,
        keyID: String,
        payload: String,
        assertion: Data?
    ) async throws -> String {
        let response = try await sendAuthenticatedEnvelope(
            path: "/v1/secure/hello",
            installID: installID,
            keyID: keyID,
            payload: payload,
            assertion: assertion,
            response: NotificationSecurityMessageResponse.self
        )
        return response.message
    }

    func sendAuthenticatedEnvelope<ResponseBody: Decodable>(
        path: String,
        installID: String,
        keyID: String,
        payload: String,
        assertion: Data?,
        response: ResponseBody.Type
    ) async throws -> ResponseBody {
        let body = NotificationSecurityAuthenticatedEnvelope(
            installID: installID,
            keyID: keyID,
            payload: payload,
            assertion: assertion?.base64EncodedString()
        )
        return try await send(
            path: path,
            body: body,
            response: response
        )
    }

    private func send<RequestBody: Encodable, ResponseBody: Decodable>(
        path: String,
        body: RequestBody,
        response: ResponseBody.Type
    ) async throws -> ResponseBody {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, urlResponse) = try await session.data(for: request)
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw NotificationSecurityHTTPError(statusCode: -1, code: "invalid_response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorResponse = try? JSONDecoder().decode(NotificationSecurityErrorResponse.self, from: data)
            throw NotificationSecurityHTTPError(
                statusCode: httpResponse.statusCode,
                code: errorResponse?.error ?? "http_\(httpResponse.statusCode)"
            )
        }

        return try JSONDecoder().decode(response, from: data)
    }
}
