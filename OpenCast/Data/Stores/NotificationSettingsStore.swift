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
    private(set) var isRegistrationConfirmed = false

    private var pendingReconciliation: PendingNotificationReconciliation?

    @ObservationIgnored private let authorizationService: any NotificationAuthorizationProviding
    @ObservationIgnored private let registrationService: any NotificationDeviceRegistrationServicing
    @ObservationIgnored private let subscriptionSyncService: any NotificationSubscriptionSyncServicing
    @ObservationIgnored private let debounceInterval: Duration
    /// Sink for the sync response's per-feed poll health; wired by
    /// OpenCastAppModel to the library's device-local persistence.
    @ObservationIgnored var feedHealthRecorder: (([NotificationFeedHealthRecord]) async -> Void)?
    @ObservationIgnored private var scheduledSyncTask: Task<Void, Never>?
    @ObservationIgnored private var pendingActivePodcastIDs: Set<String>?
    @ObservationIgnored private var pendingEnableRequest: (Bool, Set<String>, ModelContext)?
    @ObservationIgnored private var pendingRefresh: (Set<String>, ModelContext)?

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
        if pendingReconciliation == .disable {
            return "Cleanup Pending"
        }
        guard isEnabled else {
            return "Off"
        }
        guard NotificationAuthorizationService.allowsRemoteRegistration(authorizationStatus) else {
            return NotificationAuthorizationService.label(for: authorizationStatus)
        }
        guard isRegistrationConfirmed else {
            return "Registration Pending"
        }
        if pendingReconciliation == .enable {
            return "Sync Pending"
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
            pendingEnableRequest = (enabled, activePodcastIDs, modelContext)
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
        guard !isWorking else {
            pendingRefresh = (activePodcastIDs, modelContext)
            return
        }
        isWorking = true
        lastErrorMessage = nil
        await refreshRegistrationAndSubscriptions(activePodcastIDs: activePodcastIDs, modelContext: modelContext)
        isWorking = false
        await drainPendingSubscriptionSyncIfNeeded()
    }

    private func refreshRegistrationAndSubscriptions(
        activePodcastIDs: Set<String>,
        modelContext: ModelContext
    ) async {
        await load(modelContext: modelContext)
        if pendingReconciliation == .disable {
            await disableNotifications(modelContext: modelContext)
            return
        }

        guard isEnabled else {
            return
        }

        guard NotificationAuthorizationService.allowsRemoteRegistration(authorizationStatus) else {
            isRegistrationConfirmed = false
            lastErrorMessage = NotificationAuthorizationService.permissionUnavailableMessage(
                for: authorizationStatus
            )
            return
        }

        // Every activation asks APNs for the current token, but an unchanged token is uploaded
        // only once per process. A rotated token always uploads, and a backend that dropped the
        // endpoint says so through the sync response's `registrationReady`.
        let wasRegistrationConfirmed = isRegistrationConfirmed
        do {
            authorizationStatus = try await registrationService.registerCurrentDevice(
                uploadsUnchangedToken: !wasRegistrationConfirmed
            )
            isRegistrationConfirmed = true
        } catch is CancellationError {
            return
        } catch {
            isRegistrationConfirmed = false
            lastErrorMessage = error.localizedDescription
            return
        }

        if pendingReconciliation == .enable {
            await retryPendingEnable(activePodcastIDs: activePodcastIDs, modelContext: modelContext)
        } else if !wasRegistrationConfirmed || (lastSyncedAt.map({ Date.now.timeIntervalSince($0) >= Self.syncStalenessInterval }) ?? true) {
            await performSubscriptionSync(
                activePodcastIDs: activePodcastIDs,
                didUploadToken: !wasRegistrationConfirmed
            )
        }
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

    // Test seam — awaits the debounced sync task's settlement (no production
    // callers), so tests never race the debounce with a fixed grace sleep.
    func awaitScheduledSubscriptionSync() async {
        await scheduledSyncTask?.value
    }

    func syncSubscriptionsIfEnabled(activePodcastIDs: Set<String>) async {
        guard isEnabled else {
            return
        }

        guard !isWorking else {
            pendingActivePodcastIDs = activePodcastIDs
            return
        }

        isWorking = true
        lastErrorMessage = nil
        await performSubscriptionSync(activePodcastIDs: activePodcastIDs)
        isWorking = false
        await drainPendingSubscriptionSyncIfNeeded()
    }

    private func performSubscriptionSync(
        activePodcastIDs: Set<String>,
        didUploadToken: Bool = false
    ) async {
        authorizationStatus = await authorizationService.authorizationStatus()
        guard NotificationAuthorizationService.allowsRemoteRegistration(authorizationStatus) else {
            isRegistrationConfirmed = false
            lastErrorMessage = NotificationAuthorizationService.permissionUnavailableMessage(
                for: authorizationStatus
            )
            return
        }

        do {
            var didUploadToken = didUploadToken
            if !isRegistrationConfirmed {
                authorizationStatus = try await registrationService.registerCurrentDevice(uploadsUnchangedToken: true)
                isRegistrationConfirmed = true
                didUploadToken = true
            }
            let response = try await subscriptionSyncService.sync(activePodcastIDs: activePodcastIDs)
            recordSync(response)
            // The backend dropped this endpoint (for example after an APNs 410) while the token
            // stayed the same. An upload that just happened would not be helped by another.
            if response.registrationReady == false, !didUploadToken {
                authorizationStatus = try await registrationService.registerCurrentDevice(uploadsUnchangedToken: true)
                isRegistrationConfirmed = true
                if response.rejected.isEmpty {
                    lastErrorMessage = nil
                }
            }
        } catch is CancellationError {
            return
        } catch {
            lastErrorMessage = error.localizedDescription
        }
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
        isRegistrationConfirmed = false
        isEnabled = false
        pendingReconciliation = nil
        pendingActivePodcastIDs = nil
        pendingEnableRequest = nil
        pendingRefresh = nil
        lastSyncMessage = nil
        lastSyncedAt = nil
    }

    func resetAfterDataNuke() {
        scheduledSyncTask?.cancel()
        scheduledSyncTask = nil
        isEnabled = false
        isWorking = false
        isRegistrationConfirmed = false
        pendingReconciliation = nil
        pendingActivePodcastIDs = nil
        pendingEnableRequest = nil
        pendingRefresh = nil
        lastSyncMessage = nil
        lastErrorMessage = nil
        lastSyncedAt = nil
    }

    private func enableNotifications(
        activePodcastIDs: Set<String>,
        modelContext: ModelContext
    ) async {
        var didRegisterDevice = false
        isRegistrationConfirmed = false
        do {
            authorizationStatus = try await registrationService.registerCurrentDevice(uploadsUnchangedToken: true)
            didRegisterDevice = true
            isRegistrationConfirmed = true
            let response = try await subscriptionSyncService.sync(activePodcastIDs: activePodcastIDs)
            try Self.persistEnabled(true, modelContext: modelContext)
            try Self.clearPendingReconciliation(modelContext: modelContext)
            isEnabled = true
            pendingReconciliation = nil
            recordSync(response)
        } catch {
            authorizationStatus = await authorizationService.authorizationStatus()
            if didRegisterDevice || NotificationAuthorizationService.allowsRemoteRegistration(authorizationStatus) {
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
            if !(error is CancellationError) {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    private func disableNotifications(modelContext: ModelContext) async {
        isRegistrationConfirmed = false
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

    private func retryPendingEnable(
        activePodcastIDs: Set<String>,
        modelContext: ModelContext
    ) async {
        authorizationStatus = await authorizationService.authorizationStatus()
        guard NotificationAuthorizationService.allowsRemoteRegistration(authorizationStatus) else {
            isRegistrationConfirmed = false
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
            if !(error is CancellationError) {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    private func drainPendingSubscriptionSyncIfNeeded() async {
        if let (enabled, activePodcastIDs, modelContext) = pendingEnableRequest {
            pendingEnableRequest = nil
            await setEnabled(enabled, activePodcastIDs: activePodcastIDs, modelContext: modelContext)
            return
        }
        if let (activePodcastIDs, modelContext) = pendingRefresh {
            pendingRefresh = nil
            await refreshIfNeeded(activePodcastIDs: activePodcastIDs, modelContext: modelContext)
            return
        }
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
        if response.registrationReady == false {
            isRegistrationConfirmed = false
            lastErrorMessage = "Push registration needs to be renewed. OpenCast will retry when you reopen the app."
        }
        lastSyncedAt = .now
        lastSyncMessage = response.pending.isEmpty
            ? "\(response.accepted.count) synced"
            : "\(response.accepted.count) synced, \(response.pending.count) syncing"
        if !response.rejected.isEmpty {
            lastErrorMessage = "\(response.rejected.count) feed(s) rejected by notification validation."
        }

        let healthRecords = response.accepted.compactMap { accepted in
            accepted.health.map { NotificationFeedHealthRecord(feedURL: accepted.feedURL, health: $0) }
        }
        let recorder = feedHealthRecorder
        Task {
            await recorder?(healthRecords)
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
