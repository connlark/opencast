#if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
import Foundation
import UserNotifications

struct NotificationRegistrationDiagnosticService {
    private let configuration: NotificationBackendConfiguration
    private let authorizationService: NotificationAuthorizationService
    private let registrationBridge: RemoteNotificationRegistrationBridge
    private let credentialService: NotificationSecurityCredentialService
    private let secureClient: NotificationSecureAPIClient
    private let tokenStore: NotificationDeviceTokenStore

    init(
        configuration: NotificationBackendConfiguration = .current,
        authorizationService: NotificationAuthorizationService = NotificationAuthorizationService(),
        registrationBridge: RemoteNotificationRegistrationBridge = .shared,
        credentialService: NotificationSecurityCredentialService = NotificationSecurityCredentialService(),
        secureClient: NotificationSecureAPIClient = NotificationSecureAPIClient(),
        tokenStore: NotificationDeviceTokenStore = NotificationDeviceTokenStore()
    ) {
        self.configuration = configuration
        self.authorizationService = authorizationService
        self.registrationBridge = registrationBridge
        self.credentialService = credentialService
        self.secureClient = secureClient
        self.tokenStore = tokenStore
    }

    func run() async throws -> NotificationRegistrationDiagnosticResult {
        guard credentialService.isAppAttestSupported else {
            return NotificationRegistrationDiagnosticResult(
                permissionStatus: "Not Run",
                apnsRegistrationStatus: "Not Run",
                workerRegistrationStatus: "Not Run",
                testPushStatus: "Not Run",
                apnsStatus: "Not Run",
                deviceDeliveryStatus: "Not Run",
                apnsError: nil,
                detail: "App Attest is unavailable on this device."
            )
        }

        let permissionStatus = try await authorizedStatus()
        let permissionLabel = NotificationAuthorizationService.label(for: permissionStatus)
        guard NotificationAuthorizationService.allowsRemoteRegistration(permissionStatus) else {
            return NotificationRegistrationDiagnosticResult(
                permissionStatus: permissionLabel,
                apnsRegistrationStatus: "Not Run",
                workerRegistrationStatus: "Not Run",
                testPushStatus: "Not Run",
                apnsStatus: "Not Run",
                deviceDeliveryStatus: "Not Run",
                apnsError: nil,
                detail: "Notification permission is not granted."
            )
        }

        let deviceToken = try await registrationBridge.registerForRemoteNotifications()
        let deviceTokenHex = tokenStore.save(deviceToken)
        let credential = try await credentialService.ensureRegisteredCredential()
        let registrationMessage = try await registerDevice(
            deviceToken: deviceTokenHex,
            credential: credential
        )
        let deliveryTask = Task {
            try await registrationBridge.waitForDiagnosticNotification()
        }
        let pushResponse: NotificationTestPushResponse
        do {
            pushResponse = try await sendTestPush(credential: credential)
        } catch {
            deliveryTask.cancel()
            throw error
        }
        let deliveryStatus = await deliveryStatus(
            from: deliveryTask,
            apnsStatus: pushResponse.apnsStatus
        )

        return NotificationRegistrationDiagnosticResult(
            permissionStatus: permissionLabel,
            apnsRegistrationStatus: "Registered",
            workerRegistrationStatus: registrationMessage,
            testPushStatus: pushResponse.message,
            apnsStatus: pushResponse.apnsStatus.map(String.init) ?? "None",
            deviceDeliveryStatus: deliveryStatus,
            apnsError: pushResponse.apnsError,
            detail: credential.detail
        )
    }

    private func authorizedStatus() async throws -> UNAuthorizationStatus {
        let status = await authorizationService.authorizationStatus()
        if NotificationAuthorizationService.allowsRemoteRegistration(status) {
            return status
        }

        return try await authorizationService.requestAuthorization()
    }

    private func registerDevice(
        deviceToken: String,
        credential: NotificationSecurityCredential
    ) async throws -> String {
        let response = try await secureClient.sendJSONPayload(
            path: "/v1/devices/register",
            installID: credential.installID,
            keyID: credential.keyID,
            payload: NotificationDeviceRegistrationPayload(
                deviceToken: deviceToken,
                apnsEnvironment: configuration.apnsEnvironment,
                appVersion: appVersion,
                appBuild: appBuild
            ),
            response: NotificationSecurityMessageResponse.self
        )
        return response.message
    }

    private func sendTestPush(
        credential: NotificationSecurityCredential
    ) async throws -> NotificationTestPushResponse {
        try await secureClient.sendJSONPayload(
            path: "/v1/debug/send-test-push",
            installID: credential.installID,
            keyID: credential.keyID,
            payload: NotificationTestPushPayload(),
            response: NotificationTestPushResponse.self
        )
    }

    private func deliveryStatus(
        from task: Task<String, Error>,
        apnsStatus: Int?
    ) async -> String {
        guard apnsStatus == 200 else {
            task.cancel()
            return "Not Confirmed"
        }

        do {
            return try await task.value
        } catch {
            return "Not Confirmed"
        }
    }

    private var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    private var appBuild: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }
}
#endif
