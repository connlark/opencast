import DeviceCheck
import Foundation

nonisolated struct NotificationSecureAPIClient: Sendable {
    let apiClient: NotificationSecurityAPIClient
    let secureClient: AppAttestSecureAPIClient

    init(
        apiClient: NotificationSecurityAPIClient = NotificationSecurityAPIClient(),
        appAttestService: any AppAttestServiceProtocol = DeviceCheckAppAttestService.shared
    ) {
        self.apiClient = apiClient
        self.secureClient = AppAttestSecureAPIClient(
            apiClient: apiClient.appAttestClient,
            appAttestService: appAttestService
        )
    }

    func sendJSONPayload<Payload: Encodable, ResponseBody: Decodable & Sendable>(
        path: String,
        installID: String,
        keyID: String,
        payload: Payload,
        response: ResponseBody.Type
    ) async throws -> ResponseBody {
        try await secureClient.sendJSONPayload(
            path: path,
            installID: installID,
            keyID: keyID,
            payload: payload,
            response: response
        )
    }

    func sendRawPayload<ResponseBody: Decodable & Sendable>(
        path: String,
        installID: String,
        keyID: String,
        payload: String,
        response: ResponseBody.Type
    ) async throws -> ResponseBody {
        try await secureClient.sendRawPayload(
            path: path,
            installID: installID,
            keyID: keyID,
            payload: payload,
            response: response
        )
    }

    nonisolated static func encodedPayloadString<Payload: Encodable>(_ payload: Payload) throws -> String {
        try AppAttestSecureAPIClient.encodedPayloadString(payload)
    }
}
