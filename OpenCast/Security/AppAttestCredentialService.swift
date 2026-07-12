import CryptoKit
import DeviceCheck
import Foundation

nonisolated struct AppAttestCredentialService: Sendable {
    typealias CredentialValidation = @Sendable (AppAttestCredential) async throws -> String

    private let appAttestService: any AppAttestServiceProtocol
    private let apiClient: AppAttestAPIClient
    private let keychain: AppAttestKeychain

    init(
        appAttestService: any AppAttestServiceProtocol = DeviceCheckAppAttestService.shared,
        apiClient: AppAttestAPIClient,
        keychain: AppAttestKeychain
    ) {
        self.appAttestService = appAttestService
        self.apiClient = apiClient
        self.keychain = keychain
    }

    var isAppAttestSupported: Bool {
        appAttestService.isSupported
    }

    func ensureRegisteredCredential(
        validate: CredentialValidation? = nil
    ) async throws -> AppAttestCredential {
        let installID = try keychain.loadOrCreateInstallID()
        if let keyID = try keychain.loadAppAttestKeyID() {
            let credential = AppAttestCredential(
                installID: installID,
                keyID: keyID,
                secureMessage: "not_validated",
                detail: "Used registered App Attest key."
            )
            guard let validate else {
                return credential
            }

            do {
                let secureMessage = try await validate(credential)
                return AppAttestCredential(
                    installID: installID,
                    keyID: keyID,
                    secureMessage: secureMessage,
                    detail: "Used registered App Attest key."
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return try await registerFreshKey(
                    installID: installID,
                    fallbackReason: error.localizedDescription,
                    validate: validate
                )
            }
        }

        return try await registerFreshKey(
            installID: installID,
            fallbackReason: nil,
            validate: validate
        )
    }

    func loadRegisteredCredential() throws -> AppAttestCredential? {
        guard let installID = try keychain.loadInstallID(),
              let keyID = try keychain.loadAppAttestKeyID()
        else {
            return nil
        }

        return AppAttestCredential(
            installID: installID,
            keyID: keyID,
            secureMessage: "not_validated",
            detail: "Used registered App Attest key."
        )
    }

    func deleteCachedAppAttestKey() throws {
        try keychain.deleteAppAttestKeyID()
    }

    func deleteCachedCredential() throws {
        try keychain.deleteAll()
    }

    func withFreshCredentialOnRecoverableFailure<T>(
        validate: CredentialValidation? = nil,
        operation: @Sendable (AppAttestCredential) async throws -> T
    ) async throws -> T {
        try await AppAttestCredentialRecovery.withFreshCredentialOnRecoverableFailure(
            ensureCredential: {
                try await ensureRegisteredCredential(validate: validate)
            },
            deleteCachedAppAttestKey: deleteCachedAppAttestKey,
            isRecoverableServerCredentialFailure: { error in
                (error as? AppAttestHTTPError)?.isRecoverableCredentialFailure == true
            },
            operation: operation
        )
    }

    nonisolated static func isRecoverableLocalCredentialFailure(_ error: any Error) -> Bool {
        AppAttestCredentialRecovery.isRecoverableLocalCredentialFailure(error)
    }

    private func registerFreshKey(
        installID: String,
        fallbackReason: String?,
        validate: CredentialValidation?
    ) async throws -> AppAttestCredential {
        let keyID = try await appAttestService.generateKey()
        let challenge = try await apiClient.requestChallenge(installID: installID)
        let challengeHash = Data(SHA256.hash(data: Data(challenge.challenge.utf8)))
        let attestationObject = try await appAttestService.attestKey(
            keyID,
            clientDataHash: challengeHash
        )
        let registerMessage = try await apiClient.register(
            installID: installID,
            keyID: keyID,
            challengeID: challenge.challengeID,
            challenge: challenge.challenge,
            attestationObject: attestationObject
        )
        try keychain.saveAppAttestKeyID(keyID)

        let baseCredential = AppAttestCredential(
            installID: installID,
            keyID: keyID,
            secureMessage: registerMessage,
            detail: ""
        )
        let secureMessage = if let validate {
            try await validate(baseCredential)
        } else {
            registerMessage
        }

        let detail: String
        if let fallbackReason {
            detail = "Cached key was replaced after \(fallbackReason). Registration returned \(registerMessage)."
        } else {
            detail = "Registration returned \(registerMessage)."
        }

        return AppAttestCredential(
            installID: installID,
            keyID: keyID,
            secureMessage: secureMessage,
            detail: detail
        )
    }
}
