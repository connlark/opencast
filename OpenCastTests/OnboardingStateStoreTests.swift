import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Onboarding state store")
struct OnboardingStateStoreTests {
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
