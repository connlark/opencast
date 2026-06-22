#if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
import DeviceCheck
import Foundation

struct NotificationSecurityDiagnosticService {
    private static let diagnosticPayload = "hello world"

    private let appAttestService: DCAppAttestService
    private let apiClient: NotificationSecurityAPIClient
    private let credentialService: NotificationSecurityCredentialService

    init(
        appAttestService: DCAppAttestService = .shared,
        apiClient: NotificationSecurityAPIClient = NotificationSecurityAPIClient(),
        keychain: NotificationSecurityKeychain = NotificationSecurityKeychain()
    ) {
        self.appAttestService = appAttestService
        self.apiClient = apiClient
        self.credentialService = NotificationSecurityCredentialService(
            appAttestService: appAttestService,
            apiClient: apiClient,
            keychain: keychain
        )
    }

    func run() async throws -> NotificationSecurityDiagnosticResult {
        let rejectedProofMessage = try await runRejectedProofProbe()

        guard appAttestService.isSupported else {
            return NotificationSecurityDiagnosticResult(
                appAttestStatus: "Unsupported",
                rejectedProofMessage: rejectedProofMessage,
                validProofMessage: "Not Run",
                detail: "App Attest is unavailable on this device."
            )
        }

        let credential = try await credentialService.ensureRegisteredCredential()

        return NotificationSecurityDiagnosticResult(
            appAttestStatus: "Supported",
            rejectedProofMessage: rejectedProofMessage,
            validProofMessage: credential.secureMessage,
            detail: credential.detail
        )
    }

    private func runRejectedProofProbe() async throws -> String {
        do {
            return try await apiClient.secureHello(
                installID: "debug-rejection",
                keyID: "debug-rejection",
                payload: Self.diagnosticPayload,
                assertion: nil
            )
        } catch let error as NotificationSecurityHTTPError
            where error.statusCode == 401 || error.statusCode == 403 {
            return "goodbye world"
        }
    }
}
#endif
