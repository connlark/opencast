import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Analysis key notice store")
struct AnalysisKeyNoticeStoreTests {
    @Test("The seen flag's key stays stable")
    func preferenceKeyStaysStable() {
        #expect(AnalysisKeyNoticeStore.seenPreferenceKey == "aiServices.keyNoticeSeen")
    }

    @Test("The value 2 reads as seen; the value true that 2026.11.1 wrote reads as unseen")
    func seenLiterals() throws {
        #expect(AnalysisKeyNoticeStore.seenPreferenceValue == "2")

        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = AnalysisKeyNoticeStore()

        try LocalPreferenceRecord.upsert(key: AnalysisKeyNoticeStore.seenPreferenceKey, value: "true", modelContext: context)
        try context.save()
        store.load(modelContext: context)
        #expect(!store.hasSeenAIKeyNotice)

        try LocalPreferenceRecord.upsert(key: AnalysisKeyNoticeStore.seenPreferenceKey, value: "2", modelContext: context)
        try context.save()
        store.load(modelContext: context)
        #expect(store.hasSeenAIKeyNotice)
    }

    @Test("The notice is due only unseen, with no key, and with the trial service reachable")
    func gateTable() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = AnalysisKeyNoticeStore()
        store.load(modelContext: context)

        #expect(store.isNoticeDue(hasSavedKey: false, reachability: .available))
        #expect(!store.isNoticeDue(hasSavedKey: false, reachability: .unavailable))
        #expect(!store.isNoticeDue(hasSavedKey: false, reachability: .unknown))
        #expect(!store.isNoticeDue(hasSavedKey: true, reachability: .available))

        store.markSeen(modelContext: context)

        #expect(store.hasSeenAIKeyNotice)
        #expect(!store.isNoticeDue(hasSavedKey: false, reachability: .available))
    }

    @Test("Only an unseen notice with no key waits on unknown reachability")
    func awaitingReachability() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let store = AnalysisKeyNoticeStore()

        #expect(store.isAwaitingReachability(hasSavedKey: false, reachability: .unknown))
        #expect(!store.isAwaitingReachability(hasSavedKey: false, reachability: .available))
        #expect(!store.isAwaitingReachability(hasSavedKey: false, reachability: .unavailable))
        #expect(!store.isAwaitingReachability(hasSavedKey: true, reachability: .unknown))

        store.markSeen(modelContext: ModelContext(container))

        #expect(!store.isAwaitingReachability(hasSavedKey: false, reachability: .unknown))
    }

    @Test("The Settings row ignores the seen flag, hides with a key and needs the trial service reachable")
    func settingsRowRule() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let store = AnalysisKeyNoticeStore()
        store.markSeen(modelContext: ModelContext(container))

        #expect(store.showsSettingsNoticeRow(hasSavedKey: false, reachability: .available))
        #expect(!store.showsSettingsNoticeRow(hasSavedKey: true, reachability: .available))
        #expect(!store.showsSettingsNoticeRow(hasSavedKey: false, reachability: .unknown))
        #expect(!store.showsSettingsNoticeRow(hasSavedKey: false, reachability: .unavailable))
    }

    @Test("Marking the notice seen persists across a reload")
    func markSeenPersists() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let store = AnalysisKeyNoticeStore()
        store.load(modelContext: ModelContext(container))
        #expect(!store.hasSeenAIKeyNotice)

        store.markSeen(modelContext: ModelContext(container))

        let reloaded = AnalysisKeyNoticeStore()
        reloaded.load(modelContext: ModelContext(container))
        #expect(reloaded.hasSeenAIKeyNotice)
    }

    @Test("A failed save stands for the session only")
    func failedSaveStandsForTheSession() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        struct SaveFailed: Error {}
        let store = AnalysisKeyNoticeStore(save: { _ in throw SaveFailed() })

        store.markSeen(modelContext: ModelContext(container))

        #expect(store.hasSeenAIKeyNotice)
        let reloaded = AnalysisKeyNoticeStore()
        reloaded.load(modelContext: ModelContext(container))
        #expect(!reloaded.hasSeenAIKeyNotice)
    }

    @Test("Only a count the service reported is known")
    func knownRemainingUnits() {
        let store = AnalysisKeyNoticeStore()

        #expect(store.knownRemainingUnits == nil)
        store.trialStatus = .notStarted
        #expect(store.knownRemainingUnits == nil)
        store.trialStatus = .unitsLeft(3)
        #expect(store.knownRemainingUnits == 3)
        store.trialStatus = .exhausted
        #expect(store.knownRemainingUnits == 0)
        #expect(AnalysisKeyNoticeStore(trialStatus: .unitsLeft(2)).knownRemainingUnits == 2)
    }

    @Test("Before the date the sheet says what is included, whatever the status")
    func sheetBeforeTheDate() {
        let trial = AnalysisPolicyBundle.baked.trial
        let date = AIServicesCopy.trialDate(trial.startsAt)
        let units = trial.lifetimeUnits

        for status: AnalysisTrialStatus? in [nil, .notStarted, .unitsLeft(3)] {
            let copy = AnalysisKeyNoticeStore(trialStatus: status).sheetCopy(trial: trial, now: trial.startsAt.addingTimeInterval(-1))

            #expect(copy.title == "Ad detection and Chapters & Summary are included until \(date)")
            #expect(copy.paragraphs == [
                "Nothing to set up. Both features work as they do today until \(date).",
                "After that, every install keeps \(units) free analyses. Beyond those, the two features use an API key from Google or OpenAI that you add in Settings › AI Services, and that provider bills you for what you use."
            ])
        }
    }

    @Test("On or after the date the sheet states a count only when the status is known")
    func sheetFromTheDate() {
        let trial = AnalysisPolicyBundle.baked.trial
        let tail = "the two features use an API key from Google or OpenAI that you add in Settings › AI Services, and that provider bills you for what you use."

        let known = AnalysisKeyNoticeStore(trialStatus: .unitsLeft(3)).sheetCopy(trial: trial, now: trial.startsAt)
        #expect(known.title == "Ad detection and Chapters & Summary use your own key")
        #expect(known.paragraphs == ["This install has 3 free analyses left. After those, \(tail)"])
        #expect(AnalysisKeyNoticeStore(trialStatus: .unitsLeft(5)).sheetCopy(trial: trial, now: trial.startsAt).paragraphs
            == ["This install has 5 free analyses left. After those, \(tail)"])
        #expect(AnalysisKeyNoticeStore(trialStatus: .unitsLeft(1)).sheetCopy(trial: trial, now: trial.startsAt).paragraphs
            == ["This install has 1 free analysis left. After that, \(tail)"])
        for used: AnalysisTrialStatus in [.unitsLeft(0), .exhausted] {
            #expect(AnalysisKeyNoticeStore(trialStatus: used).sheetCopy(trial: trial, now: trial.startsAt).paragraphs
                == ["This install has used its free analyses. The two features now use an API key from Google or OpenAI that you add in Settings › AI Services, and that provider bills you for what you use."])
        }

        for status: AnalysisTrialStatus? in [nil, .notStarted] {
            let unknown = AnalysisKeyNoticeStore(trialStatus: status).sheetCopy(trial: trial, now: trial.startsAt.addingTimeInterval(1))
            #expect(unknown.title == "Ad detection and Chapters & Summary use your own key")
            #expect(unknown.paragraphs == ["Every install keeps \(trial.lifetimeUnits) free analyses. After those, \(tail)"])
        }
    }

    @Test("The Settings row states a count only when the status is known")
    func settingsRowText() {
        let trial = AnalysisPolicyBundle.baked.trial
        let date = AIServicesCopy.trialDate(trial.startsAt)
        let units = trial.lifetimeUnits
        let before = trial.startsAt.addingTimeInterval(-1)
        let after = trial.startsAt

        #expect(AnalysisKeyNoticeStore().settingsRowText(trial: trial, now: before) == "Included until \(date) · then \(units) free analyses")
        #expect(AnalysisKeyNoticeStore(trialStatus: .unitsLeft(3)).settingsRowText(trial: trial, now: before) == "Included until \(date) · then \(units) free analyses")
        #expect(AnalysisKeyNoticeStore().settingsRowText(trial: trial, now: after) == "Every install keeps \(units) free analyses")
        #expect(AnalysisKeyNoticeStore(trialStatus: .notStarted).settingsRowText(trial: trial, now: after) == "Every install keeps \(units) free analyses")
        #expect(AnalysisKeyNoticeStore(trialStatus: .unitsLeft(3)).settingsRowText(trial: trial, now: after) == "3 free analyses remain")
        #expect(AnalysisKeyNoticeStore(trialStatus: .unitsLeft(5)).settingsRowText(trial: trial, now: after) == "5 free analyses remain")
        #expect(AnalysisKeyNoticeStore(trialStatus: .unitsLeft(1)).settingsRowText(trial: trial, now: after) == "1 free analysis remains")
        #expect(AnalysisKeyNoticeStore(trialStatus: .unitsLeft(0)).settingsRowText(trial: trial, now: after) == "Your free analyses are used")
        #expect(AnalysisKeyNoticeStore(trialStatus: .exhausted).settingsRowText(trial: trial, now: after) == "Your free analyses are used")
    }

    @Test("The app model's notice check reads reachability and the saved keys, not the bundle's notice")
    func appModelNoticeCheck() async throws {
        var bundle = AnalysisPolicySnapshot.baked.bundle
        bundle.notice?.startsAt = .distantFuture
        let snapshot = AnalysisPolicySnapshot(bundle: bundle, source: .baked, fallbackReason: nil, lastRefreshFailure: nil)
        let reachable = AnalysisTrialReachability { true }
        let appModel = makeAppModel(snapshot: snapshot, reachability: reachable)

        #expect(!appModel.isAnalysisKeyNoticeDue())
        #expect(appModel.isAnalysisKeyNoticeAwaitingReachability())

        await reachable.resolve()
        #expect(appModel.isAnalysisKeyNoticeDue())
        #expect(!appModel.isAnalysisKeyNoticeAwaitingReachability())

        try appModel.analysisKeys.save(AnalysisKeyFixtures.key(AnalysisKeyFixtures.googleText), provider: .google, syncs: true)
        #expect(!appModel.isAnalysisKeyNoticeDue())

        let unreachable = AnalysisTrialReachability { false }
        let noTrial = makeAppModel(snapshot: .baked, reachability: unreachable)
        await unreachable.resolve()
        #expect(!noTrial.isAnalysisKeyNoticeDue())
        #expect(!noTrial.isAnalysisKeyNoticeAwaitingReachability())
    }

    private func makeAppModel(snapshot: AnalysisPolicySnapshot, reachability: AnalysisTrialReachability) -> OpenCastAppModel {
        OpenCastAppModel(
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            analysisPolicy: .fixed(snapshot),
            analysisKeys: AnalysisProviderKeyStore(storage: InMemoryAnalysisProviderKeyStorage()),
            analysisKeyTester: FixedAnalysisKeyTester(),
            analysisTrialReachability: reachability,
            allowsAutomaticFeedRefresh: false
        )
    }
}
