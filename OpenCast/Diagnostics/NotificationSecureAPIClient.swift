import DeviceCheck
import Foundation

struct NotificationSecureAPIClient {
    let apiClient: NotificationSecurityAPIClient
    let appAttestService: DCAppAttestService

    init(
        apiClient: NotificationSecurityAPIClient = NotificationSecurityAPIClient(),
        appAttestService: DCAppAttestService = .shared
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
        response: ResponseBody.Type
    ) async throws -> ResponseBody {
        let clientDataHash = NotificationSecurityRequestBinding.clientDataHash(
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
            response: response
        )
    }

    nonisolated static func encodedPayloadString<Payload: Encodable>(_ payload: Payload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }
}
