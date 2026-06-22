#if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
import Foundation

struct NotificationPollSubscriptionsDiagnosticService {
    private let credentialService: NotificationSecurityCredentialService
    private let secureClient: NotificationSecureAPIClient

    init(
        credentialService: NotificationSecurityCredentialService = NotificationSecurityCredentialService(),
        secureClient: NotificationSecureAPIClient = NotificationSecureAPIClient()
    ) {
        self.credentialService = credentialService
        self.secureClient = secureClient
    }

    func run(feedURL: String? = nil) async throws -> NotificationPollSubscriptionsDiagnosticResult {
        guard credentialService.isAppAttestSupported else {
            return NotificationPollSubscriptionsDiagnosticResult(
                pollStatus: "Not Run",
                feedsPolled: 0,
                feedsChanged: 0,
                notificationsAttempted: 0,
                apns200Count: 0,
                dedupedCount: 0,
                firstError: nil,
                detail: "App Attest is unavailable on this device."
            )
        }

        let credential = try await credentialService.ensureRegisteredCredential()
        let response = try await secureClient.sendJSONPayload(
            path: "/v1/debug/poll-subscriptions",
            installID: credential.installID,
            keyID: credential.keyID,
            payload: NotificationPollSubscriptionsPayload(feedURL: feedURL),
            response: NotificationPollSubscriptionsResponse.self
        )

        return NotificationPollSubscriptionsDiagnosticResult(
            pollStatus: response.message,
            feedsPolled: response.feedsPolled,
            feedsChanged: response.feedsChanged,
            notificationsAttempted: response.notificationsAttempted,
            apns200Count: response.apns200Count,
            dedupedCount: response.dedupedCount,
            firstError: response.firstError,
            detail: credential.detail
        )
    }
}
#endif
