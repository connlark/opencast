import Foundation
import Observation
import SwiftData
import UserNotifications

@Observable
final class NotificationSettingsStore {
    private static let enabledPreferenceKey = "notifications.newEpisodes.enabled"
    private static let pendingReconciliationPreferenceKey = "notifications.newEpisodes.pendingReconciliation"
    private static let syncStalenessInterval: TimeInterval = 15 * 60
    private static let defaultDebounceInterval: Duration = .seconds(2)

    private(set) var isEnabled = false
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var isWorking = false
    private(set) var lastSyncMessage: String?
    private(set) var lastErrorMessage: String?
    private(set) var lastSyncedAt: Date?

    private var pendingReconciliation: PendingNotificationReconciliation?

    @ObservationIgnored private let authorizationService: any NotificationAuthorizationProviding
    @ObservationIgnored private let registrationService: any NotificationDeviceRegistrationServicing
    @ObservationIgnored private let subscriptionSyncService: any NotificationSubscriptionSyncServicing
    @ObservationIgnored private let debounceInterval: Duration
    @ObservationIgnored private var scheduledSyncTask: Task<Void, Never>?
    @ObservationIgnored private var pendingActivePodcastIDs: Set<String>?

    init(
        authorizationService: any NotificationAuthorizationProviding = NotificationAuthorizationService(),
        registrationService: any NotificationDeviceRegistrationServicing = NotificationRegistrationService(),
        subscriptionSyncService: any NotificationSubscriptionSyncServicing = NotificationSubscriptionSyncService(),
        debounceInterval: Duration = NotificationSettingsStore.defaultDebounceInterval
    ) {
        self.authorizationService = authorizationService
        self.registrationService = registrationService
        self.subscriptionSyncService = subscriptionSyncService
        self.debounceInterval = debounceInterval
    }

    deinit {
        scheduledSyncTask?.cancel()
    }

    var statusText: String {
        if isWorking {
            return "Updating"
        }
        if let pendingReconciliation {
            switch pendingReconciliation {
            case .enable:
                return "Sync Pending"
            case .disable:
                return "Cleanup Pending"
            }
        }
        guard isEnabled else {
            return "Off"
        }
        guard NotificationAuthorizationService.allowsRemoteRegistration(authorizationStatus) else {
            return NotificationAuthorizationService.label(for: authorizationStatus)
        }
        return lastSyncMessage ?? "On"
    }

    var isPermissionDenied: Bool {
        authorizationStatus == .denied
    }

    func load(modelContext: ModelContext) async {
        isEnabled = (try? Self.storedEnabled(modelContext: modelContext)) ?? false
        pendingReconciliation = try? Self.storedPendingReconciliation(modelContext: modelContext)
        authorizationStatus = await authorizationService.authorizationStatus()
    }

    func setEnabled(
        _ enabled: Bool,
        activePodcastIDs: Set<String>,
        modelContext: ModelContext
    ) async {
        scheduledSyncTask?.cancel()
        scheduledSyncTask = nil
        guard !isWorking else {
            pendingActivePodcastIDs = activePodcastIDs
            return
        }

        isWorking = true
        lastErrorMessage = nil

        if enabled {
            await enableNotifications(activePodcastIDs: activePodcastIDs, modelContext: modelContext)
        } else {
            await disableNotifications(modelContext: modelContext)
        }

        isWorking = false
        await drainPendingSubscriptionSyncIfNeeded()
    }

    func refreshIfNeeded(
        activePodcastIDs: Set<String>,
        modelContext: ModelContext
    ) async {
        await load(modelContext: modelContext)
        await retryPendingReconciliationIfNeeded(
            activePodcastIDs: activePodcastIDs,
            modelContext: modelContext
        )

        guard isEnabled else {
            return
        }

        guard NotificationAuthorizationService.allowsRemoteRegistration(authorizationStatus) else {
            lastErrorMessage = NotificationAuthorizationService.permissionUnavailableMessage(
                for: authorizationStatus
            )
            return
        }

        guard lastSyncedAt.map({ Date.now.timeIntervalSince($0) >= Self.syncStalenessInterval }) ?? true else {
            return
        }

        await syncSubscriptionsIfEnabled(activePodcastIDs: activePodcastIDs)
    }

    func scheduleSubscriptionSyncIfEnabled(activePodcastIDs: Set<String>) {
        guard isEnabled || pendingReconciliation == .enable else {
            return
        }

        scheduledSyncTask?.cancel()
        scheduledSyncTask = Task { [weak self] in
            do {
                guard let debounceInterval = self?.debounceInterval else {
                    return
                }
                try await Task.sleep(for: debounceInterval)
            } catch is CancellationError {
                return
            } catch {
                return
            }
            await self?.syncSubscriptionsIfEnabled(activePodcastIDs: activePodcastIDs)
        }
    }

    func syncSubscriptionsIfEnabled(activePodcastIDs: Set<String>) async {
        guard isEnabled else {
            return
        }

        guard !isWorking else {
            pendingActivePodcastIDs = activePodcastIDs
            return
        }

        guard NotificationAuthorizationService.allowsRemoteRegistration(authorizationStatus) else {
            lastErrorMessage = NotificationAuthorizationService.permissionUnavailableMessage(
                for: authorizationStatus
            )
            return
        }

        authorizationStatus = await authorizationService.authorizationStatus()
        guard NotificationAuthorizationService.allowsRemoteRegistration(authorizationStatus) else {
            lastErrorMessage = NotificationAuthorizationService.permissionUnavailableMessage(
                for: authorizationStatus
            )
            return
        }

        isWorking = true
        lastErrorMessage = nil

        do {
            let response = try await subscriptionSyncService.sync(activePodcastIDs: activePodcastIDs)
            recordSync(response)
        } catch {
            lastErrorMessage = error.localizedDescription
        }

        isWorking = false
        await drainPendingSubscriptionSyncIfNeeded()
    }

    func deleteInstallIfRegistered() async {
        scheduledSyncTask?.cancel()
        scheduledSyncTask = nil
        do {
            try await subscriptionSyncService.deleteInstallIfRegistered()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
        registrationService.clearLocalDeviceToken()
        isEnabled = false
        pendingReconciliation = nil
        pendingActivePodcastIDs = nil
        lastSyncMessage = nil
        lastSyncedAt = nil
    }

    func resetAfterDataNuke() {
        scheduledSyncTask?.cancel()
        scheduledSyncTask = nil
        isEnabled = false
        isWorking = false
        pendingReconciliation = nil
        pendingActivePodcastIDs = nil
        lastSyncMessage = nil
        lastErrorMessage = nil
        lastSyncedAt = nil
    }

    private func enableNotifications(
        activePodcastIDs: Set<String>,
        modelContext: ModelContext
    ) async {
        var didRegisterDevice = false
        do {
            authorizationStatus = try await registrationService.registerCurrentDevice()
            didRegisterDevice = true
            let response = try await subscriptionSyncService.sync(activePodcastIDs: activePodcastIDs)
            try Self.persistEnabled(true, modelContext: modelContext)
            try Self.clearPendingReconciliation(modelContext: modelContext)
            isEnabled = true
            pendingReconciliation = nil
            recordSync(response)
        } catch {
            authorizationStatus = await authorizationService.authorizationStatus()
            if didRegisterDevice {
                do {
                    try Self.persistEnabled(true, modelContext: modelContext)
                    try Self.persistPendingReconciliation(
                        .enable,
                        modelContext: modelContext
                    )
                    isEnabled = true
                    pendingReconciliation = .enable
                    lastSyncMessage = nil
                } catch {
                    lastErrorMessage = error.localizedDescription
                    return
                }
            }
            lastErrorMessage = error.localizedDescription
        }
    }

    private func disableNotifications(modelContext: ModelContext) async {
        let firstError = await disableRemoteNotifications()
        do {
            try Self.persistEnabled(false, modelContext: modelContext)
            isEnabled = false
            lastSyncMessage = nil
            if let firstError {
                try Self.persistPendingReconciliation(
                    .disable,
                    modelContext: modelContext
                )
                pendingReconciliation = .disable
                lastErrorMessage = firstError.localizedDescription
            } else {
                try Self.clearPendingReconciliation(modelContext: modelContext)
                pendingReconciliation = nil
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func retryPendingReconciliationIfNeeded(
        activePodcastIDs: Set<String>,
        modelContext: ModelContext
    ) async {
        guard let pendingReconciliation else {
            return
        }
        guard !isWorking else {
            if pendingReconciliation == .enable {
                pendingActivePodcastIDs = activePodcastIDs
            }
            return
        }

        isWorking = true
        lastErrorMessage = nil
        switch pendingReconciliation {
        case .enable:
            await retryPendingEnable(activePodcastIDs: activePodcastIDs, modelContext: modelContext)
        case .disable:
            await disableNotifications(modelContext: modelContext)
        }
        isWorking = false
        await drainPendingSubscriptionSyncIfNeeded()
    }

    private func retryPendingEnable(
        activePodcastIDs: Set<String>,
        modelContext: ModelContext
    ) async {
        authorizationStatus = await authorizationService.authorizationStatus()
        guard NotificationAuthorizationService.allowsRemoteRegistration(authorizationStatus) else {
            lastErrorMessage = NotificationAuthorizationService.permissionUnavailableMessage(
                for: authorizationStatus
            )
            return
        }

        do {
            let response = try await subscriptionSyncService.sync(
                activePodcastIDs: activePodcastIDs
            )
            try Self.persistEnabled(true, modelContext: modelContext)
            try Self.clearPendingReconciliation(modelContext: modelContext)
            isEnabled = true
            pendingReconciliation = nil
            recordSync(response)
        } catch {
            do {
                try Self.persistPendingReconciliation(
                    .enable,
                    modelContext: modelContext
                )
                pendingReconciliation = .enable
            } catch {
                lastErrorMessage = error.localizedDescription
                return
            }
            lastErrorMessage = error.localizedDescription
        }
    }

    private func drainPendingSubscriptionSyncIfNeeded() async {
        guard let activePodcastIDs = pendingActivePodcastIDs else {
            return
        }

        pendingActivePodcastIDs = nil
        await syncSubscriptionsIfEnabled(activePodcastIDs: activePodcastIDs)
    }

    private func disableRemoteNotifications() async -> Error? {
        var firstError: Error?
        do {
            _ = try await subscriptionSyncService.syncIfRegistered(activePodcastIDs: [])
        } catch {
            firstError = error
        }

        do {
            try await registrationService.unregisterCurrentDeviceIfPossible()
        } catch {
            if firstError == nil {
                firstError = error
            }
        }
        return firstError
    }

    private func recordSync(_ response: NotificationSubscriptionSyncResponse) {
        lastSyncedAt = .now
        lastSyncMessage = "\(response.accepted.count) synced"
        if !response.rejected.isEmpty {
            lastErrorMessage = "\(response.rejected.count) feed(s) rejected by notification validation."
        }
    }

    private static func storedEnabled(modelContext: ModelContext) throws -> Bool {
        try LocalPreferenceRecord.preference(
            forKey: enabledPreferenceKey,
            modelContext: modelContext
        )?.value == "true"
    }

    private static func persistEnabled(
        _ enabled: Bool,
        modelContext: ModelContext
    ) throws {
        try LocalPreferenceRecord.upsert(
            key: enabledPreferenceKey,
            value: enabled ? "true" : "false",
            modelContext: modelContext
        )
        try modelContext.save()
    }

    private static func storedPendingReconciliation(
        modelContext: ModelContext
    ) throws -> PendingNotificationReconciliation? {
        guard let value = try LocalPreferenceRecord.preference(
            forKey: pendingReconciliationPreferenceKey,
            modelContext: modelContext
        )?.value else {
            return nil
        }
        return PendingNotificationReconciliation(rawValue: value)
    }

    private static func persistPendingReconciliation(
        _ reconciliation: PendingNotificationReconciliation,
        modelContext: ModelContext
    ) throws {
        try LocalPreferenceRecord.upsert(
            key: pendingReconciliationPreferenceKey,
            value: reconciliation.rawValue,
            modelContext: modelContext
        )
        try modelContext.save()
    }

    private static func clearPendingReconciliation(modelContext: ModelContext) throws {
        try LocalPreferenceRecord.deletePreferences(
            forKey: pendingReconciliationPreferenceKey,
            modelContext: modelContext
        )
        try modelContext.save()
    }
}
