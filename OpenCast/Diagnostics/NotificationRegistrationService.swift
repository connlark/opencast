import DeviceCheck
import Foundation
import UIKit
import UserNotifications

struct NotificationRegistrationService {
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

    func registerCurrentDevice() async throws -> UNAuthorizationStatus {
        guard credentialService.isAppAttestSupported else {
            throw NotificationRegistrationServiceError.appAttestUnavailable
        }

        let status = try await requestAuthorizationIfNeeded()
        guard NotificationAuthorizationService.allowsRemoteRegistration(status) else {
            throw NotificationRegistrationServiceError.permissionDenied(status)
        }

        let deviceToken = try await registrationBridge.registerForRemoteNotifications()
        let deviceTokenString = tokenStore.save(deviceToken)
        try await registerDeviceToken(deviceTokenString)
        return status
    }

    func unregisterCurrentDeviceIfPossible() async throws {
        guard let deviceToken = tokenStore.loadLatestToken(),
              let credential = try credentialService.loadRegisteredCredential()
        else {
            UIApplication.shared.unregisterForRemoteNotifications()
            tokenStore.clearLatestToken()
            return
        }

        let payload = NotificationDeviceUnregistrationPayload(deviceToken: deviceToken)
        _ = try await secureClient.sendJSONPayload(
            path: "/v1/devices/unregister",
            installID: credential.installID,
            keyID: credential.keyID,
            payload: payload,
            response: NotificationSecurityMessageResponse.self
        )
        UIApplication.shared.unregisterForRemoteNotifications()
        tokenStore.clearLatestToken()
    }

    func clearLocalDeviceToken() {
        UIApplication.shared.unregisterForRemoteNotifications()
        tokenStore.clearLatestToken()
    }

    private func requestAuthorizationIfNeeded() async throws -> UNAuthorizationStatus {
        let status = await authorizationService.authorizationStatus()
        guard status == .notDetermined else {
            return status
        }

        return try await authorizationService.requestAuthorization()
    }

    private func registerDeviceToken(_ deviceToken: String) async throws {
        try await credentialService.withFreshCredentialOnRecoverableFailure(
            validateWithSecureHello: false
        ) { credential in
            try await sendRegisterDeviceRequest(deviceToken: deviceToken, credential: credential)
        }
    }

    private func sendRegisterDeviceRequest(
        deviceToken: String,
        credential: NotificationSecurityCredential
    ) async throws {
        let bundle = Bundle.main
        let payload = NotificationDeviceRegistrationPayload(
            deviceToken: deviceToken,
            apnsEnvironment: configuration.apnsEnvironment,
            appVersion: bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
            appBuild: bundle.infoDictionary?["CFBundleVersion"] as? String
        )
        _ = try await secureClient.sendJSONPayload(
            path: "/v1/devices/register",
            installID: credential.installID,
            keyID: credential.keyID,
            payload: payload,
            response: NotificationSecurityMessageResponse.self
        )
    }
}

enum NotificationRegistrationServiceError: Error, LocalizedError {
    case appAttestUnavailable
    case permissionDenied(UNAuthorizationStatus)

    var errorDescription: String? {
        switch self {
        case .appAttestUnavailable:
            "App Attest is unavailable on this device."
        case .permissionDenied(let status):
            NotificationAuthorizationService.permissionUnavailableMessage(for: status)
        }
    }
}
