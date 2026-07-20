import Foundation

nonisolated struct AppAttestSecureAPIClient: Sendable {
    let apiClient: AppAttestAPIClient
    let appAttestService: any AppAttestServiceProtocol

    init(
        apiClient: AppAttestAPIClient,
        appAttestService: any AppAttestServiceProtocol
    ) {
        self.apiClient = apiClient
        self.appAttestService = appAttestService
    }

    func sendJSONPayload<Payload: Encodable, ResponseBody: Decodable>(
        path: String,
        installID: String,
        keyID: String,
        payload: Payload,
        response: ResponseBody.Type
    ) async throws -> ResponseBody {
        let payloadString = try Self.encodedPayloadString(payload)
        return try await sendRawPayload(
            path: path,
            installID: installID,
            keyID: keyID,
            payload: payloadString,
            response: response
        )
    }

    func sendRawPayload<ResponseBody: Decodable>(
        path: String,
        installID: String,
        keyID: String,
        payload: String,
        timeout: TimeInterval? = nil,
        response: ResponseBody.Type
    ) async throws -> ResponseBody {
        let clientDataHash = AppAttestRequestBinding.clientDataHash(
            method: "POST",
            path: path,
            payload: payload
        )
        let assertion = try await appAttestService.generateAssertion(
            keyID,
            clientDataHash: clientDataHash
        )
        return try await apiClient.sendAuthenticatedEnvelope(
            path: path,
            installID: installID,
            keyID: keyID,
            payload: payload,
            assertion: assertion,
            timeout: timeout,
            response: response
        )
    }

    nonisolated static func encodedPayloadString<Payload: Encodable>(_ payload: Payload) throws -> String {
        try AppAttestSignedPayloadJSONCoding.payloadString(payload)
    }
}
