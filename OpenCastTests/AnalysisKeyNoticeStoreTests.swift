import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Analysis key notice store")
struct AnalysisKeyNoticeStoreTests {
    private let now = Date(timeIntervalSince1970: 1_792_065_600)

    @Test("The seen flag's key stays stable")
    func preferenceKeyStaysStable() {
        #expect(AnalysisKeyNoticeStore.seenPreferenceKey == "aiServices.keyNoticeSeen")
    }

    @Test("The notice is due only unseen, with no key, once its start has passed")
    func gateTable() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = AnalysisKeyNoticeStore()
        store.load(modelContext: context)
        let past = try notice(startingAt: now.addingTimeInterval(-60))
        let exact = try notice(startingAt: now)
        let future = try notice(startingAt: now.addingTimeInterval(60))

        #expect(store.isNoticeDue(notice: past, hasSavedKey: false, now: now))
        #expect(store.isNoticeDue(notice: exact, hasSavedKey: false, now: now))
        #expect(!store.isNoticeDue(notice: future, hasSavedKey: false, now: now))
        #expect(!store.isNoticeDue(notice: nil, hasSavedKey: false, now: now))
        #expect(!store.isNoticeDue(notice: past, hasSavedKey: true, now: now))

        store.markSeen(modelContext: context)

        #expect(store.hasSeenAIKeyNotice)
        #expect(!store.isNoticeDue(notice: past, hasSavedKey: false, now: now))
    }

    @Test("The Settings row ignores the seen flag but hides once a key is saved")
    func settingsRowRule() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = AnalysisKeyNoticeStore()
        store.markSeen(modelContext: context)
        let past = try notice(startingAt: now.addingTimeInterval(-60))
        let future = try notice(startingAt: now.addingTimeInterval(60))

        #expect(store.showsSettingsNoticeRow(notice: past, hasSavedKey: false, now: now))
        #expect(!store.showsSettingsNoticeRow(notice: past, hasSavedKey: true, now: now))
        #expect(!store.showsSettingsNoticeRow(notice: future, hasSavedKey: false, now: now))
        #expect(!store.showsSettingsNoticeRow(notice: nil, hasSavedKey: false, now: now))
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

    @Test("Remaining units follow the trial status")
    func remainingUnits() {
        let trial = AnalysisPolicyBundle.baked.trial
        let store = AnalysisKeyNoticeStore()

        #expect(store.remainingUnits(trial: trial) == trial.lifetimeUnits)
        store.trialStatus = .notStarted
        #expect(store.remainingUnits(trial: trial) == trial.lifetimeUnits)
        store.trialStatus = .unitsLeft(3)
        #expect(store.remainingUnits(trial: trial) == 3)
        store.trialStatus = .exhausted
        #expect(store.remainingUnits(trial: trial) == 0)
        #expect(AnalysisKeyNoticeStore(trialStatus: .unitsLeft(2)).remainingUnits(trial: trial) == 2)
    }

    @Test("The app model's notice check reads the policy's notice and the saved keys")
    func appModelNoticeCheck() async throws {
        let storage = InMemoryAnalysisProviderKeyStorage()
        let appModel = OpenCastAppModel(
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            analysisPolicy: .fixed(.baked),
            analysisKeys: AnalysisProviderKeyStore(storage: storage),
            analysisKeyTester: FixedAnalysisKeyTester(),
            allowsAutomaticFeedRefresh: false
        )
        let start = try #require(AnalysisPolicyBundle.baked.notice?.startsAt)

        #expect(appModel.isAnalysisKeyNoticeDue(now: start))
        #expect(!appModel.isAnalysisKeyNoticeDue(now: start.addingTimeInterval(-1)))

        try appModel.analysisKeys.save(AnalysisKeyFixtures.key(AnalysisKeyFixtures.googleText), provider: .google, syncs: true)
        #expect(!appModel.isAnalysisKeyNoticeDue(now: start))

        let notStarted = OpenCastAppModel(
            library: LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory()),
            analysisPolicy: .fixed(AnalysisUITestFixtures.policySnapshot(variant: "notice-not-started")),
            analysisKeys: AnalysisProviderKeyStore(storage: InMemoryAnalysisProviderKeyStorage()),
            analysisKeyTester: FixedAnalysisKeyTester(),
            allowsAutomaticFeedRefresh: false
        )
        #expect(!notStarted.isAnalysisKeyNoticeDue(now: start))
    }

    private func notice(startingAt startsAt: Date) throws -> AnalysisNoticePolicy {
        var notice = try #require(AnalysisPolicyBundle.baked.notice)
        notice.startsAt = startsAt
        return notice
    }
}
