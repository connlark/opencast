import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Analysis provider selection store")
struct AnalysisProviderSelectionStoreTests {
    // Stored keys are a storage contract; the literals pin them.
    private let adDetectionKey = "aiServices.provider.adDetection"
    private let chaptersSummaryKey = "aiServices.provider.chaptersSummary"
    private let bothKeys: [AnalysisProvider: AnalysisKeyPresence] = [.google: .saved(synced: true), .openai: .saved(synced: false)]
    private let googleOnly: [AnalysisProvider: AnalysisKeyPresence] = [.google: .saved(synced: true), .openai: AnalysisKeyPresence.none]
    private let openAIOnly: [AnalysisProvider: AnalysisKeyPresence] = [.google: AnalysisKeyPresence.none, .openai: .saved(synced: true)]
    private let noKeys: [AnalysisProvider: AnalysisKeyPresence] = [.google: AnalysisKeyPresence.none, .openai: AnalysisKeyPresence.none]

    @Test("Preference keys stay stable")
    func preferenceKeysStayStable() {
        #expect(AnalysisProviderSelectionStore.adDetectionPreferenceKey == adDetectionKey)
        #expect(AnalysisProviderSelectionStore.chaptersSummaryPreferenceKey == chaptersSummaryKey)
        #expect(AnalysisProviderSelectionStore.preferenceKey(for: .adDetection) == adDetectionKey)
        #expect(AnalysisProviderSelectionStore.preferenceKey(for: .chaptersSummary) == chaptersSummaryKey)
    }

    @Test("Nothing is stored until a choice is saved, and a saved choice reloads")
    func choicesPersistAndReload() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = AnalysisProviderSelectionStore()
        store.load(modelContext: context)
        #expect(store.storedProviders.isEmpty)

        let savedAdDetection = store.setProvider(.openai, for: .adDetection, modelContext: context)
        let savedChapters = store.setProvider(.google, for: .chaptersSummary, modelContext: context)

        #expect(savedAdDetection && savedChapters)
        #expect(store.storedProvider(for: .adDetection) == .openai)
        #expect(store.lastErrorMessage == nil)
        #expect(try storedValues(forKey: adDetectionKey, in: container) == ["openai"])
        #expect(try storedValues(forKey: chaptersSummaryKey, in: container) == ["google"])

        let reloaded = AnalysisProviderSelectionStore()
        reloaded.load(modelContext: ModelContext(container))
        #expect(reloaded.storedProviders == [.adDetection: .openai, .chaptersSummary: .google])

        // A second choice updates the row instead of adding one.
        let changed = store.setProvider(.google, for: .adDetection, modelContext: context)
        #expect(changed)
        #expect(try storedValues(forKey: adDetectionKey, in: container) == ["google"])
    }

    @Test("A failed save keeps the previous choice and reports the error")
    func failedSaveKeepsPreviousChoice() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        struct SaveFailed: Error {}
        let store = AnalysisProviderSelectionStore(save: { _ in throw SaveFailed() })
        store.load(modelContext: context)

        let saved = store.setProvider(.openai, for: .adDetection, modelContext: context)

        #expect(!saved)
        #expect(store.storedProvider(for: .adDetection) == nil)
        #expect(store.lastErrorMessage != nil)
        #expect(try storedValues(forKey: adDetectionKey, in: container).isEmpty)
    }

    @Test("An unknown stored provider reads as no choice")
    func unknownStoredProviderIsIgnored() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        context.insert(LocalPreferenceRecord(key: adDetectionKey, value: "anthropic"))
        try context.save()
        let store = AnalysisProviderSelectionStore()

        store.load(modelContext: context)

        #expect(store.storedProvider(for: .adDetection) == nil)
    }

    @Test("The effective provider follows the rule's table")
    func effectiveProviderRule() {
        typealias Rule = AnalysisProviderSelectionStore
        // The stored choice when eligible.
        #expect(Rule.effectiveProvider(stored: .openai, eligible: [.google, .openai]) == .openai)
        // A stored choice without a key falls back, and the single eligible provider wins.
        #expect(Rule.effectiveProvider(stored: .openai, eligible: [.google]) == .google)
        #expect(Rule.effectiveProvider(stored: .google, eligible: [.openai]) == .openai)
        #expect(Rule.effectiveProvider(stored: nil, eligible: [.openai]) == .openai)
        // Several eligible and nothing stored: Google, the trial's provider.
        #expect(Rule.effectiveProvider(stored: nil, eligible: [.google, .openai]) == .google)
        // None eligible: no key route.
        #expect(Rule.effectiveProvider(stored: .google, eligible: []) == nil)
        #expect(Rule.effectiveProvider(stored: nil, eligible: []) == nil)
    }

    @Test("Eligibility needs a saved key and an entry for the feature")
    func eligibilityNeedsKeyAndEntry() throws {
        let store = AnalysisProviderSelectionStore()
        let baked = AnalysisPolicySnapshot.baked
        let withoutOpenAIChapters = AnalysisUITestFixtures.policySnapshot(variant: "no-openai-chapters")

        #expect(store.eligibleProviders(for: .adDetection, presences: bothKeys, snapshot: baked) == [.google, .openai])
        #expect(store.eligibleProviders(for: .chaptersSummary, presences: bothKeys, snapshot: baked) == [.google, .openai])
        #expect(store.eligibleProviders(for: .adDetection, presences: googleOnly, snapshot: baked) == [.google])
        #expect(store.eligibleProviders(for: .adDetection, presences: noKeys, snapshot: baked).isEmpty)
        #expect(store.eligibleProviders(for: .adDetection, presences: [:], snapshot: baked).isEmpty)

        // A provider without a Chapters & Summary entry is hidden there only.
        #expect(store.eligibleProviders(for: .adDetection, presences: bothKeys, snapshot: withoutOpenAIChapters) == [.google, .openai])
        #expect(store.eligibleProviders(for: .chaptersSummary, presences: bothKeys, snapshot: withoutOpenAIChapters) == [.google])
        #expect(store.eligibleProviders(for: .chaptersSummary, presences: openAIOnly, snapshot: withoutOpenAIChapters).isEmpty)
    }

    @Test("A stored choice survives its key's removal and returns with the key")
    func storedChoiceReturnsWithItsKey() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = AnalysisProviderSelectionStore()
        let snapshot = AnalysisPolicySnapshot.baked
        let saved = store.setProvider(.openai, for: .chaptersSummary, modelContext: context)
        #expect(saved)

        #expect(store.effectiveProvider(for: .chaptersSummary, presences: bothKeys, snapshot: snapshot) == .openai)
        #expect(store.effectiveProvider(for: .chaptersSummary, presences: googleOnly, snapshot: snapshot) == .google)
        #expect(store.storedProvider(for: .chaptersSummary) == .openai)
        #expect(store.effectiveProvider(for: .chaptersSummary, presences: bothKeys, snapshot: snapshot) == .openai)
        #expect(store.effectiveProvider(for: .chaptersSummary, presences: noKeys, snapshot: snapshot) == nil)

        // The stored choice is not eligible where the bundle hides it.
        let withoutOpenAIChapters = AnalysisUITestFixtures.policySnapshot(variant: "no-openai-chapters")
        #expect(store.effectiveProvider(for: .chaptersSummary, presences: bothKeys, snapshot: withoutOpenAIChapters) == .google)
    }

    @Test("The app model resolves the effective provider from its key store, choice and policy")
    func appModelResolvesEffectiveProvider() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let storage = InMemoryAnalysisProviderKeyStorage(seeded: [
            .openai: (AnalysisKeyFixtures.key(AnalysisKeyFixtures.openAIText), syncs: true),
        ])
        let appModel = OpenCastAppModel(
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            analysisPolicy: .fixed(AnalysisUITestFixtures.policySnapshot(variant: "no-openai-chapters")),
            analysisKeys: AnalysisProviderKeyStore(storage: storage),
            analysisKeyTester: FixedAnalysisKeyTester(),
            allowsAutomaticFeedRefresh: false
        )
        #expect(appModel.effectiveAnalysisProvider(for: .adDetection) == nil)

        await appModel.analysisKeys.refreshPresences()

        #expect(appModel.effectiveAnalysisProvider(for: .adDetection) == .openai)
        #expect(appModel.effectiveAnalysisProvider(for: .chaptersSummary) == nil)

        try appModel.analysisKeys.save(AnalysisKeyFixtures.key(AnalysisKeyFixtures.googleText), provider: .google, syncs: true)
        let saved = appModel.analysisProviderSelection.setProvider(.openai, for: .adDetection, modelContext: context)
        #expect(saved)
        #expect(appModel.effectiveAnalysisProvider(for: .adDetection) == .openai)
        #expect(appModel.effectiveAnalysisProvider(for: .chaptersSummary) == .google)
    }

    private func storedValues(forKey key: String, in container: ModelContainer) throws -> [String] {
        let descriptor = FetchDescriptor<LocalPreferenceRecord>(
            predicate: #Predicate<LocalPreferenceRecord> { record in
                record.key == key
            }
        )
        return try ModelContext(container).fetch(descriptor).map(\.value)
    }
}
