import Foundation

/// Deletes only an existing install. It deliberately never repairs credentials
/// or registers a key, including when the server has already forgotten it.
nonisolated struct AppAttestInstallDeregistration: Sendable {
    enum Outcome: Sendable, Equatable {
        case notRegistered
        case deregistered
    }

    let keychainService: String
    let keepsInstallID: Bool
    private let credentials: AppAttestCredentialService
    private let secureClient: AppAttestSecureAPIClient
    private let suspension: AppAttestSuspension

    init(
        baseURL: URL,
        keychainService: String,
        transport: any AppAttestHTTPTransport = URLSession.shared,
        appAttestService: any AppAttestServiceProtocol = DeviceCheckAppAttestService.shared,
        keepsInstallID: Bool,
        suspension: AppAttestSuspension = .shared,
        assertionGate: AppAttestAssertionGate = .shared
    ) {
        self.keychainService = keychainService
        self.keepsInstallID = keepsInstallID
        self.suspension = suspension
        let api = AppAttestAPIClient(
            configuration: .init(baseURL: baseURL, keychainService: keychainService),
            transport: transport
        )
        credentials = AppAttestCredentialService(
            appAttestService: appAttestService, apiClient: api,
            keychain: AppAttestKeychain(service: keychainService), suspension: suspension
        )
        secureClient = AppAttestSecureAPIClient(
            apiClient: api, appAttestService: appAttestService, assertionGate: assertionGate
        )
    }

    var isWaitingForRegistration: Bool {
        suspension.hasRegistrationSection(keychainService: keychainService)
    }

    func deregisterIfRegistered() async throws -> Outcome {
        await suspension.drain(keychainService: keychainService)
        try Task.checkCancellation()
        guard let credential = try credentials.loadRegisteredCredential() else { return .notRegistered }
        do {
            _ = try await secureClient.sendRawPayload(
                path: "/v1/install/delete",
                installID: credential.installID,
                keyID: credential.keyID,
                payload: "{}",
                timeout: 10,
                exemptFromSuspension: true,
                response: AppAttestMessageResponse.self
            )
        } catch let error as AppAttestHTTPError where error.statusCode == 401 && error.code == "unknown_key" {
            // A previous delete may have committed even if its reply was lost.
        }
        // Also covers a late unknown_key response from a cancelled deadline.
        try Task.checkCancellation()
        if keepsInstallID {
            try credentials.deleteCachedAppAttestKey()
        } else {
            try credentials.deleteCachedCredential()
        }
        return .deregistered
    }
}
