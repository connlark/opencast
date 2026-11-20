import Foundation

nonisolated struct AppAttestSecureAPIClient: Sendable {
    let apiClient: AppAttestAPIClient
    let appAttestService: any AppAttestServiceProtocol
    private let assertionGate: AppAttestAssertionGate

    init(
        apiClient: AppAttestAPIClient,
        appAttestService: any AppAttestServiceProtocol,
        assertionGate: AppAttestAssertionGate = .shared
    ) {
        self.apiClient = apiClient
        self.appAttestService = appAttestService
        self.assertionGate = assertionGate
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
        exemptFromSuspension: Bool = false,
        response: ResponseBody.Type
    ) async throws -> ResponseBody {
        // One gate turn spans issuance to response, the counter-race retry included, so a key's
        // counters reach the server in issuance order.
        try await assertionGate.withSerializedSend(
            keyID: keyID, exemptFromSuspension: exemptFromSuspension
        ) {
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
                // Another process (app or extension) can still land a higher counter first; a fresh
                // assertion picks up the advanced counter.
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

    /// Every status comes back undecoded, the body read capped at `maximumBodyBytes`. One gate
    /// turn spans issuance, the post and the whole body read; a 401 `invalid_counter` is resent
    /// once inside the turn.
    func sendRawPayloadForRawResponse(
        path: String,
        installID: String,
        keyID: String,
        payload: String,
        timeout: TimeInterval?,
        maximumBodyBytes: Int
    ) async throws -> AppAttestRawHTTPResponse {
        try await assertionGate.withSerializedSend(keyID: keyID) {
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
        try Task.checkCancellation()
        let clientDataHash = AppAttestRequestBinding.clientDataHash(
            method: "POST",
            path: path,
            payload: payload
        )
        let assertion = try await appAttestService.generateAssertion(
            keyID,
            clientDataHash: clientDataHash
        )
        try Task.checkCancellation()
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
        try Task.checkCancellation()
        let clientDataHash = AppAttestRequestBinding.clientDataHash(
            method: "POST",
            path: path,
            payload: payload
        )
        let assertion = try await appAttestService.generateAssertion(
            keyID,
            clientDataHash: clientDataHash
        )
        try Task.checkCancellation()
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
