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
    private let adDetectionModelKey = "aiServices.model.adDetection"
    private let chaptersSummaryModelKey = "aiServices.model.chaptersSummary"
    private let bothKeys: [AnalysisProvider: AnalysisKeyPresence] = [.google: .saved(synced: true), .openai: .saved(synced: false)]
    private let googleOnly: [AnalysisProvider: AnalysisKeyPresence] = [.google: .saved(synced: true), .openai: AnalysisKeyPresence.none]
    private let openAIOnly: [AnalysisProvider: AnalysisKeyPresence] = [.google: AnalysisKeyPresence.none, .openai: .saved(synced: true)]
    private let noKeys: [AnalysisProvider: AnalysisKeyPresence] = [.google: AnalysisKeyPresence.none, .openai: AnalysisKeyPresence.none]
    private let secondGoogleModel = AnalysisUITestFixtures.policySnapshot(variant: "second-google-model")

    @Test("Nothing is stored until a choice is saved, and each feature's choice reloads")
    func choicesPersistAndReload() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = AnalysisProviderSelectionStore()
        store.load(modelContext: context)
        #expect(store.storedChoices.isEmpty)

        let savedAdDetection = store.select(.init(provider: .google, modelID: "gemini-second"), for: .adDetection, modelContext: context)
        let savedChapters = store.select(.init(provider: .openai, modelID: "gpt-6.1-sol"), for: .chaptersSummary, modelContext: context)

        #expect(savedAdDetection && savedChapters)
        #expect(store.lastErrorMessage == nil)
        #expect(try storedValues(forKey: adDetectionKey, in: container) == ["google"])
        #expect(try storedValues(forKey: adDetectionModelKey, in: container) == ["gemini-second"])
        #expect(try storedValues(forKey: chaptersSummaryKey, in: container) == ["openai"])
        #expect(try storedValues(forKey: chaptersSummaryModelKey, in: container) == ["gpt-6.1-sol"])

        let reloaded = AnalysisProviderSelectionStore()
        reloaded.load(modelContext: ModelContext(container))
        #expect(reloaded.storedChoices == [
            .adDetection: .init(provider: .google, modelID: "gemini-second"),
            .chaptersSummary: .init(provider: .openai, modelID: "gpt-6.1-sol"),
        ])
        #expect(reloaded.effectiveModel(for: .adDetection, presences: bothKeys, snapshot: secondGoogleModel)?.modelID == "gemini-second")
        #expect(reloaded.effectiveModel(for: .chaptersSummary, presences: bothKeys, snapshot: secondGoogleModel)?.modelID == "gpt-6.1-sol")

        // A second choice updates the rows instead of adding them.
        let changed = store.select(.init(provider: .google, modelID: "gemini-3.8-flash"), for: .adDetection, modelContext: context)
        #expect(changed)
        #expect(try storedValues(forKey: adDetectionKey, in: container) == ["google"])
        #expect(try storedValues(forKey: adDetectionModelKey, in: container) == ["gemini-3.8-flash"])
    }

    @Test("A provider saved without a model takes that provider's default entry and writes nothing")
    func providerWithoutModelTakesTheDefault() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        try LocalPreferenceRecord.upsert(key: chaptersSummaryKey, value: "google", modelContext: context)
        try context.save()
        let store = AnalysisProviderSelectionStore()

        store.load(modelContext: context)

        #expect(store.storedChoice(for: .chaptersSummary) == .init(provider: .google, modelID: nil))
        #expect(store.effectiveModel(for: .chaptersSummary, presences: bothKeys, snapshot: .baked)?.modelID == "gemini-3.8-flash")
        #expect(try storedValues(forKey: chaptersSummaryModelKey, in: container).isEmpty)
    }

    @Test("A failed save keeps the previous choice and reports the error")
    func failedSaveKeepsPreviousChoice() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        struct SaveFailed: Error {}
        let store = AnalysisProviderSelectionStore(save: { _ in throw SaveFailed() })
        store.load(modelContext: context)

        let saved = store.select(.init(provider: .openai, modelID: "gpt-6.1-sol"), for: .adDetection, modelContext: context)

        #expect(!saved)
        #expect(store.storedChoice(for: .adDetection) == nil)
        #expect(store.lastErrorMessage != nil)
        #expect(try storedValues(forKey: adDetectionKey, in: container).isEmpty)
        #expect(try storedValues(forKey: adDetectionModelKey, in: container).isEmpty)
    }

    @Test("The effective provider follows the rule's table")
    func effectiveProviderRule() {
        typealias Rule = AnalysisProviderSelectionStore
        #expect(Rule.effectiveProvider(stored: .openai, eligible: [.google, .openai]) == .openai)
        #expect(Rule.effectiveProvider(stored: .openai, eligible: [.google]) == .google)
        #expect(Rule.effectiveProvider(stored: .google, eligible: [.openai]) == .openai)
        #expect(Rule.effectiveProvider(stored: nil, eligible: [.openai]) == .openai)
        #expect(Rule.effectiveProvider(stored: nil, eligible: [.google, .openai]) == .google)
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

        #expect(store.eligibleProviders(for: .adDetection, presences: bothKeys, snapshot: withoutOpenAIChapters) == [.google, .openai])
        #expect(store.eligibleProviders(for: .chaptersSummary, presences: bothKeys, snapshot: withoutOpenAIChapters) == [.google])
        #expect(store.eligibleProviders(for: .chaptersSummary, presences: openAIOnly, snapshot: withoutOpenAIChapters).isEmpty)
    }

    @Test("A stored model applies under its own provider while the bundle lists it, and returns with its key")
    func storedModelReturnsWithItsKey() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = AnalysisProviderSelectionStore()
        let snapshot = secondGoogleModel
        let saved = store.select(.init(provider: .google, modelID: "gemini-second"), for: .chaptersSummary, modelContext: context)
        #expect(saved)

        #expect(store.effectiveModel(for: .chaptersSummary, presences: bothKeys, snapshot: snapshot)?.modelID == "gemini-second")
        var collidingBundle = snapshot.bundle
        var openAISecond = try #require(collidingBundle.features.chaptersSummary.allowedModels.first { $0.provider == .openai })
        openAISecond.modelID = "gemini-second"
        collidingBundle.features.chaptersSummary.additionalModels.append(openAISecond)
        let colliding = AnalysisPolicySnapshot(bundle: collidingBundle, source: .baked, fallbackReason: nil, lastRefreshFailure: nil)
        #expect(store.effectiveModel(for: .chaptersSummary, presences: openAIOnly, snapshot: colliding)?.modelID == "gpt-6.1-sol")
        #expect(store.storedChoice(for: .chaptersSummary) == .init(provider: .google, modelID: "gemini-second"))
        #expect(store.effectiveModel(for: .chaptersSummary, presences: bothKeys, snapshot: snapshot)?.modelID == "gemini-second")
        #expect(store.effectiveModel(for: .chaptersSummary, presences: noKeys, snapshot: snapshot) == nil)

        var delistedBundle = snapshot.bundle
        delistedBundle.features.chaptersSummary.additionalModels = []
        let delisted = AnalysisPolicySnapshot(bundle: delistedBundle, source: .baked, fallbackReason: nil, lastRefreshFailure: nil)
        #expect(store.effectiveModel(for: .chaptersSummary, presences: bothKeys, snapshot: delisted)?.modelID == "gemini-3.8-flash")
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
