import SwiftData
import Testing
import UserNotifications
@testable import OpenCast

@MainActor
@Suite("Notification settings store")
struct NotificationSettingsStoreTests {
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
        try await Task.sleep(for: .milliseconds(20))

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

    func registerCurrentDevice() async throws -> UNAuthorizationStatus {
        .authorized
    }

    func unregisterCurrentDeviceIfPossible() async throws {
        unregisterCallCount += 1
    }

    func clearLocalDeviceToken() {}
}

@MainActor
private final class HangingNotificationRegistrationService: NotificationDeviceRegistrationServicing {
    private var registerContinuation: CheckedContinuation<Void, Never>?

    func registerCurrentDevice() async throws -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            registerContinuation = continuation
        }
        return .authorized
    }

    func unregisterCurrentDeviceIfPossible() async throws {}

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
                .map { NotificationSubscriptionSyncAccepted(feedURL: $0, title: nil) },
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
    case syncFailed
    case cleanupFailed

    var errorDescription: String? {
        switch self {
        case .syncFailed:
            "Subscription sync failed."
        case .cleanupFailed:
            "Notification cleanup failed."
        }
    }
}
