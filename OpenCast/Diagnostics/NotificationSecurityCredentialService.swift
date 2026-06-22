import CryptoKit
import DeviceCheck
import Foundation

struct NotificationSecurityCredentialService {
    private static let diagnosticPayload = "hello world"

    private let appAttestService: DCAppAttestService
    private let apiClient: NotificationSecurityAPIClient
    private let keychain: NotificationSecurityKeychain
    private let secureClient: NotificationSecureAPIClient

    init(
        appAttestService: DCAppAttestService = .shared,
        apiClient: NotificationSecurityAPIClient = NotificationSecurityAPIClient(),
        keychain: NotificationSecurityKeychain = NotificationSecurityKeychain()
    ) {
        self.appAttestService = appAttestService
        self.apiClient = apiClient
        self.keychain = keychain
        self.secureClient = NotificationSecureAPIClient(
            apiClient: apiClient,
            appAttestService: appAttestService
        )
    }

    var isAppAttestSupported: Bool {
        appAttestService.isSupported
    }

    func ensureRegisteredCredential(
        validateWithSecureHello: Bool = true
    ) async throws -> NotificationSecurityCredential {
        let installID = try keychain.loadOrCreateInstallID()
        if let keyID = try keychain.loadAppAttestKeyID() {
            guard validateWithSecureHello else {
                return NotificationSecurityCredential(
                    installID: installID,
                    keyID: keyID,
                    secureMessage: "not_validated",
                    detail: "Used registered App Attest key."
                )
            }

            do {
                let secureMessage = try await runSecureHello(
                    installID: installID,
                    keyID: keyID
                )
                return NotificationSecurityCredential(
                    installID: installID,
                    keyID: keyID,
                    secureMessage: secureMessage,
                    detail: "Used registered App Attest key."
                )
            } catch {
                return try await registerFreshKey(
                    installID: installID,
                    fallbackReason: error.localizedDescription,
                    validateWithSecureHello: validateWithSecureHello
                )
            }
        }

        return try await registerFreshKey(
            installID: installID,
            fallbackReason: nil,
            validateWithSecureHello: validateWithSecureHello
        )
    }

    func loadRegisteredCredential() throws -> NotificationSecurityCredential? {
        guard let installID = try keychain.loadInstallID(),
              let keyID = try keychain.loadAppAttestKeyID()
        else {
            return nil
        }

        return NotificationSecurityCredential(
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
        validateWithSecureHello: Bool = false,
        operation: (NotificationSecurityCredential) async throws -> T
    ) async throws -> T {
        do {
            let credential = try await ensureRegisteredCredential(
                validateWithSecureHello: validateWithSecureHello
            )
            return try await operation(credential)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error where Self.isRecoverableLocalCredentialFailure(error) {
            try deleteCachedAppAttestKey()
            let credential = try await ensureRegisteredCredential(
                validateWithSecureHello: validateWithSecureHello
            )
            return try await operation(credential)
        } catch let error as NotificationSecurityHTTPError where error.isRecoverableCredentialFailure {
            try deleteCachedAppAttestKey()
            let credential = try await ensureRegisteredCredential(
                validateWithSecureHello: validateWithSecureHello
            )
            return try await operation(credential)
        }
    }

    nonisolated static func isRecoverableLocalCredentialFailure(_ error: any Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == DCError.errorDomain else {
            return false
        }

        return nsError.code == DCError.Code.invalidInput.rawValue
            || nsError.code == DCError.Code.invalidKey.rawValue
    }

    private func registerFreshKey(
        installID: String,
        fallbackReason: String?,
        validateWithSecureHello: Bool
    ) async throws -> NotificationSecurityCredential {
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

        let secureMessage = if validateWithSecureHello {
            try await runSecureHello(
                installID: installID,
                keyID: keyID
            )
        } else {
            registerMessage
        }

        let detail: String
        if let fallbackReason {
            detail = "Cached key was replaced after \(fallbackReason). Registration returned \(registerMessage)."
        } else {
            detail = "Registration returned \(registerMessage)."
        }

        return NotificationSecurityCredential(
            installID: installID,
            keyID: keyID,
            secureMessage: secureMessage,
            detail: detail
        )
    }

    private func runSecureHello(
        installID: String,
        keyID: String
    ) async throws -> String {
        let response = try await secureClient.sendRawPayload(
            path: "/v1/secure/hello",
            installID: installID,
            keyID: keyID,
            payload: Self.diagnosticPayload,
            response: NotificationSecurityMessageResponse.self
        )
        return response.message
    }
}
