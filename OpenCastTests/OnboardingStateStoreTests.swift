import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Onboarding state store")
struct OnboardingStateStoreTests {
    @Test("Absent preference presents onboarding")
    func absentPreferencePresentsOnboarding() throws {
        let context = try makeContext()
        let store = OnboardingStateStore()

        store.load(modelContext: context)

        #expect(store.shouldPresentOnboarding)
        #expect(!store.isCompleted)
        #expect(store.lastErrorMessage == nil)
    }

    @Test("Completed preference suppresses onboarding")
    func completedPreferenceSuppressesOnboarding() throws {
        let context = try makeContext()
        try LocalPreferenceRecord.upsert(
            key: OnboardingStateStore.completedPreferenceKey,
            value: "true",
            modelContext: context
        )
        try context.save()
        let store = OnboardingStateStore()

        store.load(modelContext: context)

        #expect(!store.shouldPresentOnboarding)
        #expect(store.isCompleted)
    }

    @Test("Active synced subscriptions still present onboarding")
    func activeSyncedSubscriptionsStillPresentOnboarding() throws {
        let context = try makeContext()
        context.insert(SubscriptionRecord(feedURL: "https://example.com/feed.xml", title: "Existing Show"))
        try context.save()
        let store = OnboardingStateStore()

        store.load(modelContext: context)

        #expect(store.shouldPresentOnboarding)
        #expect(!store.isCompleted)
        #expect(try LocalPreferenceRecord.preference(
            forKey: OnboardingStateStore.completedPreferenceKey,
            modelContext: context
        ) == nil)
    }

    @Test("Archived synced subscriptions still present onboarding")
    func archivedSyncedSubscriptionsStillPresentOnboarding() throws {
        let context = try makeContext()
        context.insert(SubscriptionRecord(
            feedURL: "https://example.com/archived.xml",
            title: "Archived Show",
            isArchived: true
        ))
        try context.save()
        let store = OnboardingStateStore()

        store.load(modelContext: context)

        #expect(store.shouldPresentOnboarding)
        #expect(!store.isCompleted)
    }

    @Test("Mark completed persists local preference")
    func markCompletedPersistsLocalPreference() throws {
        let context = try makeContext()
        let store = OnboardingStateStore()

        #expect(store.markCompleted(modelContext: context))

        let reloadedStore = OnboardingStateStore()
        reloadedStore.load(modelContext: context)
        #expect(reloadedStore.isCompleted)
        #expect(try LocalPreferenceRecord.preference(
            forKey: OnboardingStateStore.completedPreferenceKey,
            modelContext: context
        )?.value == "true")
    }

    @Test("Reset makes onboarding present again")
    func resetMakesOnboardingPresentAgain() throws {
        let context = try makeContext()
        let store = OnboardingStateStore()
        #expect(store.markCompleted(modelContext: context))

        #expect(store.reset(modelContext: context))

        let reloadedStore = OnboardingStateStore()
        reloadedStore.load(modelContext: context)
        #expect(reloadedStore.shouldPresentOnboarding)
        #expect(try LocalPreferenceRecord.preference(
            forKey: OnboardingStateStore.completedPreferenceKey,
            modelContext: context
        ) == nil)
    }

    private func makeContext() throws -> ModelContext {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        return ModelContext(container)
    }
}
