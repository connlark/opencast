import Foundation

nonisolated struct NotificationSecurityAPIClient: Sendable {
    let appAttestClient: AppAttestAPIClient

    init(
        baseURL: URL = NotificationBackendConfiguration.current.workerBaseURL,
        transport: any AppAttestHTTPTransport = URLSession.shared
    ) {
        self.appAttestClient = AppAttestAPIClient(
            configuration: AppAttestClientConfiguration(
                baseURL: baseURL,
                keychainService: NotificationBackendConfiguration.current.keychainService
            ),
            transport: transport
        )
    }

    func requestChallenge(installID: String) async throws -> AppAttestChallengeResponse {
        try await appAttestClient.requestChallenge(installID: installID)
    }

    func register(
        installID: String,
        keyID: String,
        challengeID: String,
        challenge: String,
        attestationObject: Data
    ) async throws -> String {
        try await appAttestClient.register(
            installID: installID,
            keyID: keyID,
            challengeID: challengeID,
            challenge: challenge,
            attestationObject: attestationObject
        )
    }

    func secureHello(
        installID: String,
        keyID: String,
        payload: String,
        assertion: Data?
    ) async throws -> String {
        let response = try await appAttestClient.sendAuthenticatedEnvelope(
            path: "/v1/secure/hello",
            installID: installID,
            keyID: keyID,
            payload: payload,
            assertion: assertion,
            response: AppAttestMessageResponse.self
        )
        return response.message
    }
}
