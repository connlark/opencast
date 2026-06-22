#if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
import Foundation

struct NotificationSubscriptionSyncDiagnosticService {
    private let credentialService: NotificationSecurityCredentialService
    private let secureClient: NotificationSecureAPIClient

    init(
        credentialService: NotificationSecurityCredentialService = NotificationSecurityCredentialService(),
        secureClient: NotificationSecureAPIClient = NotificationSecureAPIClient()
    ) {
        self.credentialService = credentialService
        self.secureClient = secureClient
    }

    func run(activePodcastIDs: Set<String>) async throws -> NotificationSubscriptionSyncDiagnosticResult {
        guard credentialService.isAppAttestSupported else {
            return NotificationSubscriptionSyncDiagnosticResult(
                syncStatus: "Not Run",
                acceptedCount: 0,
                rejectedCount: 0,
                rejectedSummary: "None",
                detail: "App Attest is unavailable on this device."
            )
        }

        let credential = try await credentialService.ensureRegisteredCredential()
        let payload = NotificationSubscriptionSyncPayload(
            subscriptions: activePodcastIDs
                .sorted()
                .map {
                    NotificationSubscriptionSyncItem(
                        feedURL: $0,
                        notificationsEnabled: true
                    )
                }
        )
        let response = try await secureClient.sendJSONPayload(
            path: "/v1/subscriptions/sync",
            installID: credential.installID,
            keyID: credential.keyID,
            payload: payload,
            response: NotificationSubscriptionSyncResponse.self
        )

        return NotificationSubscriptionSyncDiagnosticResult(
            syncStatus: response.message,
            acceptedCount: response.accepted.count,
            rejectedCount: response.rejected.count,
            rejectedSummary: Self.rejectedSummary(response.rejected),
            detail: credential.detail
        )
    }

    private static func rejectedSummary(
        _ rejected: [NotificationSubscriptionSyncRejected]
    ) -> String {
        guard !rejected.isEmpty else {
            return "None"
        }

        return rejected
            .prefix(3)
            .map { "\($0.error): \($0.feedURL)" }
            .joined(separator: "\n")
    }
}
#endif
