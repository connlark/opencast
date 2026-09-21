import SwiftData
import Testing
import UserNotifications
@testable import OpenCast

@MainActor
@Suite("Notification settings store")
struct NotificationSettingsStoreTests {
    @Test("Launching an opted-in installation restores a disabled backend with either token", arguments: ["same", "rotated"])
    func launchRestoresDisabledRegistration(token: String) async throws {
        let context = try makeEnabledContext()
        let registration = ImmediateNotificationRegistrationService()
        // An earlier process uploaded "same"; the backend has since dropped the endpoint.
        registration.uploadedToken = "same"
        registration.currentToken = token
        let sync = MockNotificationSubscriptionSyncService()
        let store = NotificationSettingsStore(
            authorizationService: StubNotificationAuthorizationService(),
            registrationService: registration,
            subscriptionSyncService: sync
        )
        await store.load(modelContext: context)
        #expect(store.statusText == "Registration Pending")
        #expect(registration.backendToken == nil)
        await store.refreshIfNeeded(activePodcastIDs: ["https://example.com/feed.xml"], modelContext: context)
        #expect(registration.backendToken == token)
        #expect(store.statusText == "1 synced")
    }

    @Test("Later activations ask APNs again but upload only a rotated token")
    func laterActivationsUploadOnlyRotatedToken() async throws {
        let context = try makeEnabledContext()
        let registration = ImmediateNotificationRegistrationService()
        let sync = MockNotificationSubscriptionSyncService()
        let store = NotificationSettingsStore(
            authorizationService: StubNotificationAuthorizationService(),
            registrationService: registration,
            subscriptionSyncService: sync
        )
        await store.refreshIfNeeded(activePodcastIDs: ["https://example.com/feed.xml"], modelContext: context)
        #expect(registration.uploadCount == 1)

        await store.refreshIfNeeded(activePodcastIDs: ["https://example.com/feed.xml"], modelContext: context)
        #expect(registration.registerCallCount == 2)
        #expect(registration.uploadCount == 1)

        registration.currentToken = "rotated"
        await store.refreshIfNeeded(activePodcastIDs: ["https://example.com/feed.xml"], modelContext: context)
        #expect(registration.uploadCount == 2)
        #expect(registration.backendToken == "rotated")
        #expect(store.isRegistrationConfirmed)
        #expect(sync.syncCalls.count == 1)
    }

    @Test("A sync reporting a disabled endpoint re-uploads the unchanged token in the same pass")
    func syncInvalidationRenewsRegistration() async throws {
        let context = try makeEnabledContext()
        let registration = ImmediateNotificationRegistrationService()
        let sync = MockNotificationSubscriptionSyncService(syncOutcomes: [
            .success(NotificationSubscriptionSyncResponse(message: "synced", accepted: [], rejected: [])),
            .success(NotificationSubscriptionSyncResponse(
                message: "synced", accepted: [], rejected: [], registrationReady: false
            )),
        ])
        let store = NotificationSettingsStore(
            authorizationService: StubNotificationAuthorizationService(),
            registrationService: registration,
            subscriptionSyncService: sync
        )
        await store.refreshIfNeeded(activePodcastIDs: [], modelContext: context)
        #expect(registration.uploadCount == 1)

        registration.backendToken = nil
        await store.syncSubscriptionsIfEnabled(activePodcastIDs: [])
        #expect(registration.backendToken == "same")
        #expect(registration.uploadCount == 2)
        #expect(store.isRegistrationConfirmed)
        #expect(store.lastErrorMessage == nil)
        #expect(store.statusText == "0 synced")
    }

    @Test("Registration failure retries without toggling, including an initial opt-in", arguments: [true, false])
    func failedRegistrationRetries(alreadyEnabled: Bool) async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = alreadyEnabled ? try makeEnabledContext() : ModelContext(container)
        let registration = ImmediateNotificationRegistrationService()
        registration.failure = NotificationSettingsTestError.registrationFailed
        let sync = MockNotificationSubscriptionSyncService()
        let store = NotificationSettingsStore(
            authorizationService: StubNotificationAuthorizationService(),
            registrationService: registration,
            subscriptionSyncService: sync
        )
        if alreadyEnabled {
            await store.refreshIfNeeded(activePodcastIDs: [], modelContext: context)
        } else {
            await store.setEnabled(true, activePodcastIDs: [], modelContext: context)
        }
        #expect(store.isEnabled)
        #expect(store.statusText == "Registration Pending")
        #expect(store.lastErrorMessage == "Push registration failed.")
        #expect(sync.syncCalls.isEmpty)
        registration.failure = nil
        await store.refreshIfNeeded(activePodcastIDs: ["https://example.com/feed.xml"], modelContext: context)
        #expect(store.statusText == "1 synced")
        #expect(store.lastErrorMessage == nil)
        #expect(registration.registerCallCount == 2)
    }

    @Test("A successful sync reporting a disabled endpoint never claims readiness")
    func syncReportsInvalidation() async throws {
        let context = try makeEnabledContext()
        let registration = ImmediateNotificationRegistrationService()
        let sync = MockNotificationSubscriptionSyncService(syncOutcomes: [.success(
            NotificationSubscriptionSyncResponse(message: "synced", accepted: [], rejected: [], registrationReady: false)
        )])
        let store = NotificationSettingsStore(
            authorizationService: StubNotificationAuthorizationService(),
            registrationService: registration,
            subscriptionSyncService: sync
        )
        await store.refreshIfNeeded(activePodcastIDs: [], modelContext: context)
        #expect(store.statusText == "Registration Pending")
        #expect(!store.isRegistrationConfirmed)
        await store.refreshIfNeeded(activePodcastIDs: [], modelContext: context)
        #expect(store.statusText == "0 synced")
        #expect(store.isRegistrationConfirmed)
    }

    @Test("Revoked permission prevents automatic registration and allows recovery after regrant")
    func revokedPermission() async throws {
        let context = try makeEnabledContext()
        let authorization = StubNotificationAuthorizationService(status: .denied)
        let registration = ImmediateNotificationRegistrationService()
        let sync = MockNotificationSubscriptionSyncService()
        let store = NotificationSettingsStore(
            authorizationService: authorization, registrationService: registration, subscriptionSyncService: sync
        )
        await store.refreshIfNeeded(activePodcastIDs: [], modelContext: context)
        #expect(store.isPermissionDenied)
        #expect(registration.registerCallCount == 0)
        #expect(sync.syncCalls.isEmpty)
        authorization.status = .authorized
        await store.refreshIfNeeded(activePodcastIDs: [], modelContext: context)
        #expect(store.isRegistrationConfirmed)
    }

    @Test("Explicit opt-out survives launch and unsolicited-callback reconciliation")
    func optedOutNeverRegisters() async throws {
        let context = try makeEnabledContext()
        let registration = ImmediateNotificationRegistrationService()
        let store = NotificationSettingsStore(
            authorizationService: StubNotificationAuthorizationService(),
            registrationService: registration,
            subscriptionSyncService: MockNotificationSubscriptionSyncService()
        )
        await store.load(modelContext: context)
        await store.setEnabled(false, activePodcastIDs: [], modelContext: context)
        await store.refreshIfNeeded(activePodcastIDs: [], modelContext: context)
        #expect(registration.registerCallCount == 0)
        #expect(registration.unregisterCallCount == 1)
        #expect(store.statusText == "Off")
    }

    @Test("Opt-out requested during launch recovery runs after registration and wins")
    func optOutDuringRecovery() async throws {
        let context = try makeEnabledContext()
        let registration = HangingNotificationRegistrationService()
        let store = NotificationSettingsStore(
            authorizationService: StubNotificationAuthorizationService(),
            registrationService: registration,
            subscriptionSyncService: MockNotificationSubscriptionSyncService()
        )
        let task = Task { await store.refreshIfNeeded(activePodcastIDs: [], modelContext: context) }
        try #require(await registration.waitForRegisterRequest())
        await store.setEnabled(false, activePodcastIDs: [], modelContext: context)
        registration.releaseRegister()
        await task.value
        #expect(registration.unregisterCallCount == 1)
        #expect(store.statusText == "Off")
        await store.refreshIfNeeded(activePodcastIDs: [], modelContext: context)
        #expect(registration.registerCallCount == 1)
    }

    @Test("An explicit enable racing launch registration is serialized")
    func enableDuringRecovery() async throws {
        let context = try makeEnabledContext()
        let registration = HangingNotificationRegistrationService()
        let store = NotificationSettingsStore(
            authorizationService: StubNotificationAuthorizationService(),
            registrationService: registration,
            subscriptionSyncService: MockNotificationSubscriptionSyncService()
        )
        let task = Task { await store.refreshIfNeeded(activePodcastIDs: [], modelContext: context) }
        try #require(await registration.waitForRegisterRequest())
        await store.setEnabled(true, activePodcastIDs: [], modelContext: context)
        #expect(registration.registerCallCount == 1)
        registration.releaseRegister()
        try #require(await registration.waitForRegisterRequest())
        #expect(registration.registerCallCount == 2)
        registration.releaseRegister()
        await task.value
        #expect(store.isRegistrationConfirmed)
        #expect(store.lastErrorMessage == nil)
    }

    @Test("Scheduled sync during an in-flight operation drains after the operation")
    func scheduledSyncDuringInFlightOperationDrainsAfterOperation() async throws {
        let context = try makeEnabledContext()
        let registration = HangingNotificationRegistrationService()
        let sync = MockNotificationSubscriptionSyncService()
        let store = NotificationSettingsStore(
            authorizationService: StubNotificationAuthorizationService(),
            registrationService: registration,
            subscriptionSyncService: sync,
            debounceInterval: .milliseconds(5)
        )
        await store.load(modelContext: context)

        let task = Task { @MainActor in
            await store.setEnabled(
                true,
                activePodcastIDs: ["https://example.com/initial.xml"],
                modelContext: context
            )
        }
        let didRequestRegistration = await registration.waitForRegisterRequest()
        #expect(didRequestRegistration)
        store.scheduleSubscriptionSyncIfEnabled(
            activePodcastIDs: ["https://example.com/latest.xml"]
        )
        // Settle the debounced sync (it records the pending set against the
        // busy window) before releasing registration — no grace sleep to race.
        await store.awaitScheduledSubscriptionSync()

        registration.releaseRegister()
        await task.value

        #expect(sync.syncCalls == [
            ["https://example.com/initial.xml"],
            ["https://example.com/latest.xml"],
        ])
    }

    @Test("Multiple busy-window sync requests send only the latest set")
    func multipleBusyWindowSyncRequestsSendOnlyLatestSet() async throws {
        let context = try makeEnabledContext()
        let registration = HangingNotificationRegistrationService()
        let sync = MockNotificationSubscriptionSyncService()
        let store = NotificationSettingsStore(
            authorizationService: StubNotificationAuthorizationService(),
            registrationService: registration,
            subscriptionSyncService: sync,
            debounceInterval: .milliseconds(5)
        )
        await store.load(modelContext: context)

        let task = Task { @MainActor in
            await store.setEnabled(
                true,
                activePodcastIDs: ["https://example.com/initial.xml"],
                modelContext: context
            )
        }
        let didRequestRegistration = await registration.waitForRegisterRequest()
        #expect(didRequestRegistration)
        await store.syncSubscriptionsIfEnabled(activePodcastIDs: ["https://example.com/first.xml"])
        await store.syncSubscriptionsIfEnabled(activePodcastIDs: ["https://example.com/last.xml"])

        registration.releaseRegister()
        await task.value

        #expect(sync.syncCalls == [
            ["https://example.com/initial.xml"],
            ["https://example.com/last.xml"],
        ])
    }

    @Test("Enable sync failure is retried on the next refresh with the latest subscriptions")
    func enableSyncFailureRetriesOnNextRefresh() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let sync = MockNotificationSubscriptionSyncService(
            syncOutcomes: [.failure(NotificationSettingsTestError.syncFailed)]
        )
        let store = NotificationSettingsStore(
            authorizationService: StubNotificationAuthorizationService(),
            registrationService: ImmediateNotificationRegistrationService(),
            subscriptionSyncService: sync
        )

        await store.setEnabled(
            true,
            activePodcastIDs: ["https://example.com/original.xml"],
            modelContext: context
        )
        #expect(store.isEnabled)
        #expect(store.statusText == "Sync Pending")

        await store.refreshIfNeeded(
            activePodcastIDs: [
                "https://example.com/original.xml",
                "https://example.com/new.xml",
            ],
            modelContext: context
        )

        #expect(sync.syncCalls == [
            ["https://example.com/original.xml"],
            [
                "https://example.com/new.xml",
                "https://example.com/original.xml",
            ],
        ])
        #expect(store.statusText == "2 synced")
        #expect(store.lastErrorMessage == nil)
    }

    @Test("Disable cleanup failure is retried and successful disable clears retry state")
    func disableCleanupFailureRetriesAndSuccessfulDisableClearsRetryState() async throws {
        let context = try makeEnabledContext()
        let sync = MockNotificationSubscriptionSyncService(
            syncIfRegisteredOutcomes: [.failure(NotificationSettingsTestError.cleanupFailed)]
        )
        let registration = ImmediateNotificationRegistrationService()
        let store = NotificationSettingsStore(
            authorizationService: StubNotificationAuthorizationService(),
            registrationService: registration,
            subscriptionSyncService: sync
        )
        await store.load(modelContext: context)

        await store.setEnabled(
            false,
            activePodcastIDs: ["https://example.com/feed.xml"],
            modelContext: context
        )
        #expect(!store.isEnabled)
        #expect(store.statusText == "Cleanup Pending")
        #expect(sync.syncIfRegisteredCalls == [[]])

        await store.refreshIfNeeded(
            activePodcastIDs: ["https://example.com/feed.xml"],
            modelContext: context
        )
        #expect(!store.isEnabled)
        #expect(store.statusText == "Off")
        #expect(sync.syncIfRegisteredCalls == [[], []])
        #expect(registration.unregisterCallCount == 2)

        await store.refreshIfNeeded(
            activePodcastIDs: ["https://example.com/feed.xml"],
            modelContext: context
        )
        #expect(sync.syncIfRegisteredCalls == [[], []])
    }

    private func makeEnabledContext() throws -> ModelContext {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        try LocalPreferenceRecord.upsert(
            key: "notifications.newEpisodes.enabled",
            value: "true",
            modelContext: context
        )
        try context.save()
        return context
    }
}

@MainActor
private final class StubNotificationAuthorizationService: NotificationAuthorizationProviding {
    var status: UNAuthorizationStatus

    init(status: UNAuthorizationStatus = .authorized) {
        self.status = status
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        status
    }
}

@MainActor
private final class ImmediateNotificationRegistrationService: NotificationDeviceRegistrationServicing {
    private(set) var unregisterCallCount = 0
    private(set) var registerCallCount = 0
    private(set) var uploadCount = 0
    var currentToken = "same"
    var uploadedToken: String?
    var backendToken: String?
    var failure: Error?

    func registerCurrentDevice(uploadsUnchangedToken: Bool) async throws -> UNAuthorizationStatus {
        registerCallCount += 1
        if let failure { throw failure }
        guard uploadsUnchangedToken || uploadedToken != currentToken else {
            return .authorized
        }
        uploadCount += 1
        uploadedToken = currentToken
        backendToken = currentToken
        return .authorized
    }

    func unregisterCurrentDeviceIfPossible() async throws {
        unregisterCallCount += 1
        backendToken = nil
    }

    func clearLocalDeviceToken() {}
}

@MainActor
private final class HangingNotificationRegistrationService: NotificationDeviceRegistrationServicing {
    private var registerContinuation: CheckedContinuation<Void, Never>?
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    func registerCurrentDevice(uploadsUnchangedToken: Bool) async throws -> UNAuthorizationStatus {
        registerCallCount += 1
        await withCheckedContinuation { continuation in
            registerContinuation = continuation
        }
        return .authorized
    }

    func unregisterCurrentDeviceIfPossible() async throws { unregisterCallCount += 1 }

    func clearLocalDeviceToken() {}

    @MainActor
    func releaseRegister() {
        registerContinuation?.resume()
        registerContinuation = nil
    }

    @MainActor
    func waitForRegisterRequest() async -> Bool {
        for _ in 0..<1_000 {
            if registerContinuation != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return registerContinuation != nil
    }
}

@MainActor
private final class MockNotificationSubscriptionSyncService: NotificationSubscriptionSyncServicing {
    private var syncOutcomes: [NotificationSettingsSyncOutcome]
    private var syncIfRegisteredOutcomes: [NotificationSettingsSyncIfRegisteredOutcome]
    private(set) var syncCalls: [Set<String>] = []
    private(set) var syncIfRegisteredCalls: [Set<String>] = []

    init(
        syncOutcomes: [NotificationSettingsSyncOutcome] = [],
        syncIfRegisteredOutcomes: [NotificationSettingsSyncIfRegisteredOutcome] = []
    ) {
        self.syncOutcomes = syncOutcomes
        self.syncIfRegisteredOutcomes = syncIfRegisteredOutcomes
    }

    func sync(activePodcastIDs: Set<String>) async throws -> NotificationSubscriptionSyncResponse {
        syncCalls.append(activePodcastIDs)
        guard !syncOutcomes.isEmpty else {
            return Self.response(for: activePodcastIDs)
        }

        switch syncOutcomes.removeFirst() {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        }
    }

    func syncIfRegistered(activePodcastIDs: Set<String>) async throws -> NotificationSubscriptionSyncResponse? {
        syncIfRegisteredCalls.append(activePodcastIDs)
        guard !syncIfRegisteredOutcomes.isEmpty else {
            return Self.response(for: activePodcastIDs)
        }

        switch syncIfRegisteredOutcomes.removeFirst() {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        }
    }

    func deleteInstallIfRegistered() async throws {}

    private static func response(
        for activePodcastIDs: Set<String>
    ) -> NotificationSubscriptionSyncResponse {
        NotificationSubscriptionSyncResponse(
            message: "synced",
            accepted: activePodcastIDs
                .sorted()
                .map { NotificationSubscriptionSyncAccepted(feedURL: $0, title: nil, health: nil) },
            rejected: []
        )
    }
}

private enum NotificationSettingsSyncOutcome {
    case success(NotificationSubscriptionSyncResponse)
    case failure(Error)
}

private enum NotificationSettingsSyncIfRegisteredOutcome {
    case success(NotificationSubscriptionSyncResponse?)
    case failure(Error)
}

private enum NotificationSettingsTestError: Error, LocalizedError {
    case registrationFailed
    case syncFailed
    case cleanupFailed

    var errorDescription: String? {
        switch self {
        case .registrationFailed:
            "Push registration failed."
        case .syncFailed:
            "Subscription sync failed."
        case .cleanupFailed:
            "Notification cleanup failed."
        }
    }
}
