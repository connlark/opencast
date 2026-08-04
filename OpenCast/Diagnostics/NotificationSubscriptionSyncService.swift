import Foundation

struct NotificationSubscriptionSyncService {
    private let credentialService: NotificationSecurityCredentialService
    private let secureClient: NotificationSecureAPIClient

    init(
        credentialService: NotificationSecurityCredentialService = NotificationSecurityCredentialService(),
        secureClient: NotificationSecureAPIClient = NotificationSecureAPIClient()
    ) {
        self.credentialService = credentialService
        self.secureClient = secureClient
    }

    func sync(activePodcastIDs: Set<String>) async throws -> NotificationSubscriptionSyncResponse {
        try await credentialService.withFreshCredentialOnRecoverableFailure(
            validateWithSecureHello: false
        ) { credential in
            return try await sendSyncRequest(activePodcastIDs: activePodcastIDs, credential: credential)
        }
    }

    func syncIfRegistered(activePodcastIDs: Set<String>) async throws -> NotificationSubscriptionSyncResponse? {
        // The guard keeps the "never registers a fresh install" contract;
        // past it, recoverable credential failures re-attest and retry
        // exactly like `sync` instead of failing with no recovery.
        guard try credentialService.loadRegisteredCredential() != nil else {
            return nil
        }

        return try await credentialService.withFreshCredentialOnRecoverableFailure(
            validateWithSecureHello: false
        ) { credential in
            try await sendSyncRequest(activePodcastIDs: activePodcastIDs, credential: credential)
        }
    }

    func deleteInstallIfRegistered() async throws {
        guard let credential = try credentialService.loadRegisteredCredential() else {
            return
        }

        _ = try await secureClient.sendJSONPayload(
            path: "/v1/install/delete",
            installID: credential.installID,
            keyID: credential.keyID,
            payload: NotificationEmptyPayload(),
            response: AppAttestMessageResponse.self
        )
        try credentialService.deleteCachedCredential()
    }

    private func sendSyncRequest(
        activePodcastIDs: Set<String>,
        credential: AppAttestCredential
    ) async throws -> NotificationSubscriptionSyncResponse {
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
        return try await secureClient.sendJSONPayload(
            path: "/v1/subscriptions/sync",
            installID: credential.installID,
            keyID: credential.keyID,
            payload: payload,
            response: NotificationSubscriptionSyncResponse.self
        )
    }
}
