import DeviceCheck
import Foundation

nonisolated struct NotificationSecurityCredentialService: Sendable {
    private static let diagnosticPayload = "hello world"

    private let credentialService: AppAttestCredentialService
    private let secureHelloValidation: AppAttestCredentialService.CredentialValidation

    init(
        appAttestService: any AppAttestServiceProtocol = DeviceCheckAppAttestService.shared,
        apiClient: NotificationSecurityAPIClient = NotificationSecurityAPIClient(),
        keychain: AppAttestKeychain = AppAttestKeychain(
            service: NotificationBackendConfiguration.current.keychainService
        )
    ) {
        self.credentialService = AppAttestCredentialService(
            appAttestService: appAttestService,
            apiClient: apiClient.appAttestClient,
            keychain: keychain
        )
        let secureClient = AppAttestSecureAPIClient(
            apiClient: apiClient.appAttestClient,
            appAttestService: appAttestService
        )
        self.secureHelloValidation = { credential in
            let response = try await secureClient.sendRawPayload(
                path: "/v1/secure/hello",
                installID: credential.installID,
                keyID: credential.keyID,
                payload: Self.diagnosticPayload,
                response: AppAttestMessageResponse.self
            )
            return response.message
        }
    }

    var isAppAttestSupported: Bool {
        credentialService.isAppAttestSupported
    }

    func ensureRegisteredCredential(
        validateWithSecureHello: Bool = true
    ) async throws -> AppAttestCredential {
        try await credentialService.ensureRegisteredCredential(
            validate: validateWithSecureHello ? secureHelloValidation : nil
        )
    }

    func loadRegisteredCredential() throws -> AppAttestCredential? {
        try credentialService.loadRegisteredCredential()
    }

    func deleteCachedAppAttestKey() throws {
        try credentialService.deleteCachedAppAttestKey()
    }

    func deleteCachedCredential() throws {
        try credentialService.deleteCachedCredential()
    }

    func withFreshCredentialOnRecoverableFailure<T>(
        validateWithSecureHello: Bool = false,
        operation: @Sendable (AppAttestCredential) async throws -> T
    ) async throws -> T {
        try await credentialService.withFreshCredentialOnRecoverableFailure(
            validate: validateWithSecureHello ? secureHelloValidation : nil,
            operation: operation
        )
    }

    nonisolated static func isRecoverableLocalCredentialFailure(_ error: any Error) -> Bool {
        AppAttestCredentialService.isRecoverableLocalCredentialFailure(error)
    }
}
