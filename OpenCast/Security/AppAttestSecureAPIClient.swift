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

    func sendJSONPayload<Payload: Encodable, ResponseBody: Decodable & Sendable>(
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

    func sendRawPayload<ResponseBody: Decodable & Sendable>(
        path: String,
        installID: String,
        keyID: String,
        payload: String,
        timeout: TimeInterval? = nil,
        response: ResponseBody.Type
    ) async throws -> ResponseBody {
        // One gate turn spans issuance → response (including the single
        // counter-race retry), so a key's counters reach the server in
        // issuance order regardless of which service is sending.
        try await AppAttestAssertionGate.shared.withSerializedSend(keyID: keyID) {
            do {
                return try await issueAssertionAndSend(
                    path: path,
                    installID: installID,
                    keyID: keyID,
                    payload: payload,
                    timeout: timeout,
                    response: response
                )
            } catch let error as AppAttestHTTPError where error.isCounterRaceFailure {
                // Another process (app vs. extension) can still land a higher
                // counter first; a fresh assertion picks up the advanced
                // counter without the maximal delete-key + re-attest recovery.
                return try await issueAssertionAndSend(
                    path: path,
                    installID: installID,
                    keyID: keyID,
                    payload: payload,
                    timeout: timeout,
                    response: response
                )
            }
        }
    }

    /// ``sendRawPayload(path:installID:keyID:payload:timeout:response:)``
    /// with the reply undecoded: every status comes back as a response, and
    /// the body is read capped at `maximumBodyBytes`. One gate turn spans
    /// issuance, the post and the whole body read; a 401 `invalid_counter`
    /// is sent again once inside the turn with a fresh assertion.
    func sendRawPayloadForRawResponse(
        path: String,
        installID: String,
        keyID: String,
        payload: String,
        timeout: TimeInterval?,
        maximumBodyBytes: Int
    ) async throws -> AppAttestRawHTTPResponse {
        try await AppAttestAssertionGate.shared.withSerializedSend(keyID: keyID) {
            let first = try await issueAssertionAndSendForRawResponse(
                path: path,
                installID: installID,
                keyID: keyID,
                payload: payload,
                timeout: timeout,
                maximumBodyBytes: maximumBodyBytes
            )
            guard first.isCounterRaceFailure else {
                return first
            }
            return try await issueAssertionAndSendForRawResponse(
                path: path,
                installID: installID,
                keyID: keyID,
                payload: payload,
                timeout: timeout,
                maximumBodyBytes: maximumBodyBytes
            )
        }
    }

    private func issueAssertionAndSendForRawResponse(
        path: String,
        installID: String,
        keyID: String,
        payload: String,
        timeout: TimeInterval?,
        maximumBodyBytes: Int
    ) async throws -> AppAttestRawHTTPResponse {
        let clientDataHash = AppAttestRequestBinding.clientDataHash(
            method: "POST",
            path: path,
            payload: payload
        )
        let assertion = try await appAttestService.generateAssertion(
            keyID,
            clientDataHash: clientDataHash
        )
        return try await apiClient.sendAuthenticatedEnvelopeForRawResponse(
            path: path,
            installID: installID,
            keyID: keyID,
            payload: payload,
            assertion: assertion,
            timeout: timeout,
            maximumBodyBytes: maximumBodyBytes
        )
    }

    private func issueAssertionAndSend<ResponseBody: Decodable & Sendable>(
        path: String,
        installID: String,
        keyID: String,
        payload: String,
        timeout: TimeInterval?,
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
