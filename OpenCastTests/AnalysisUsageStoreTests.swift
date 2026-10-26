import Foundation
import OpenCastAnalysis
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Analysis usage store")
struct AnalysisUsageStoreTests {
    private let october15 = Date(timeIntervalSince1970: 1_792_065_600) // 2026-10-15T12:00:00Z
    private let october16 = Date(timeIntervalSince1970: 1_792_152_000) // 2026-10-16T12:00:00Z
    private let october31Late = Date(timeIntervalSince1970: 1_793_489_400) // 2026-10-31T23:30:00Z
    private let november1Early = Date(timeIntervalSince1970: 1_793_494_800) // 2026-11-01T01:00:00Z
    private let november20 = Date(timeIntervalSince1970: 1_795_176_000) // 2026-11-20T12:00:00Z

    @Test("Preference keys stay stable")
    func preferenceKeysStayStable() {
        #expect(AnalysisUsageStore.preferenceKey(for: .google) == "aiServices.usage.google")
        #expect(AnalysisUsageStore.preferenceKey(for: .openai) == "aiServices.usage.openai")
    }

    @Test("The month is the Gregorian UTC month, wherever the listener is")
    func monthIsGregorianUTC() throws {
        #expect(AnalysisUsageStore.month(of: october31Late) == "2026-10")
        #expect(AnalysisUsageStore.month(of: november1Early) == "2026-11")

        // The same instants fall in the other month in Tokyo and Los Angeles.
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(tokyo.component(.month, from: october31Late) == 11)
        #expect(losAngeles.component(.month, from: november1Early) == 10)

        // A non-Gregorian calendar on the device changes nothing.
        let buddhistYear = Calendar(identifier: .buddhist).component(.year, from: october15)
        #expect(buddhistYear != 2026)
        #expect(AnalysisUsageStore.month(of: october15) == "2026-10")
    }

    @Test("A run recorded twice under its id adds once, also after a reload")
    func runIDRecordsOnce() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let clock = TestClock(october15)
        let store = AnalysisUsageStore(now: { clock.now })
        store.load(modelContext: context)

        #expect(store.record(provider: .google, feature: .adDetection, inputTokens: 1_000, outputTokens: 200, at: october15, runID: "run-a", modelContext: context))
        #expect(store.record(provider: .google, feature: .adDetection, inputTokens: 1_000, outputTokens: 200, at: october15, runID: "run-a", modelContext: context))
        let reloaded = AnalysisUsageStore(now: { clock.now })
        reloaded.load(modelContext: ModelContext(container))
        #expect(reloaded.record(provider: .google, feature: .adDetection, inputTokens: 1_000, outputTokens: 200, at: october15, runID: "run-a", modelContext: context))
        #expect(reloaded.record(provider: .google, feature: .adDetection, inputTokens: 10, outputTokens: 2, at: october15, runID: "run-b", modelContext: context))

        #expect(reloaded.usage(for: .google).monthInputTokens == 1_010)
        #expect(reloaded.usage(for: .google).monthOutputTokens == 202)
    }

    @Test("A run recorded again with larger totals adds only the difference; equal or smaller totals add nothing")
    func runIDCountsOnlyTheGrowth() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let clock = TestClock(october15)
        let store = AnalysisUsageStore(now: { clock.now })
        store.load(modelContext: context)

        // A partial run counted at a cancel, then the resumed run's totals.
        #expect(store.record(provider: .google, feature: .adDetection, inputTokens: 400, outputTokens: 50, at: october15, runID: "run-a", modelContext: context))
        let reloaded = AnalysisUsageStore(now: { clock.now })
        reloaded.load(modelContext: ModelContext(container))
        #expect(reloaded.record(provider: .google, feature: .adDetection, inputTokens: 1_000, outputTokens: 200, at: october15, runID: "run-a", modelContext: context))
        #expect(reloaded.record(provider: .google, feature: .adDetection, inputTokens: 1_000, outputTokens: 200, at: october15, runID: "run-a", modelContext: context))
        #expect(reloaded.record(provider: .google, feature: .adDetection, inputTokens: 900, outputTokens: 100, at: october15, runID: "run-a", modelContext: context))

        let usage = reloaded.usage(for: .google)
        #expect(usage.monthInputTokens == 1_000)
        #expect(usage.monthOutputTokens == 200)
        #expect(usage.lastRun?.inputTokens == 1_000)
        #expect(usage.lastRun?.outputTokens == 200)
    }

    @Test("A recorded run reads back as the last run and this month's totals")
    func recordAndRead() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let clock = TestClock(october15)
        let store = AnalysisUsageStore(now: { clock.now })
        store.load(modelContext: context)
        #expect(store.usage(for: .google) == AnalysisProviderUsage(lastRun: nil, month: "2026-10", monthInputTokens: 0, monthOutputTokens: 0))

        let first = store.record(provider: .google, feature: .adDetection, inputTokens: 1_000, outputTokens: 200, at: october15, modelContext: context)
        clock.now = october16
        let second = store.record(provider: .google, feature: .chaptersSummary, inputTokens: 500, outputTokens: 50, at: october16, modelContext: context)

        #expect(first && second)
        let usage = store.usage(for: .google)
        #expect(usage.month == "2026-10")
        #expect(usage.monthInputTokens == 1_500)
        #expect(usage.monthOutputTokens == 250)
        #expect(usage.lastRun == AnalysisProviderUsage.Run(feature: "chapters_summary", inputTokens: 500, outputTokens: 50, at: october16))
        #expect(store.usage(for: .openai).lastRun == nil)
        #expect(store.lastErrorMessage == nil)
    }

    @Test("Totals read zero once the UTC month turns, and the stored bucket stays")
    func rolloverIsAReadProjection() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let clock = TestClock(october31Late)
        let store = AnalysisUsageStore(now: { clock.now })
        store.load(modelContext: context)
        let recorded = store.record(provider: .openai, feature: .adDetection, inputTokens: 900, outputTokens: 90, at: october31Late, modelContext: context)
        #expect(recorded)

        clock.now = november1Early
        // The projection follows `currentMonth`, which moves on refresh.
        #expect(store.usage(for: .openai).monthInputTokens == 900)
        store.refreshCurrentMonth()

        let usage = store.usage(for: .openai)
        #expect(store.currentMonth == "2026-11")
        #expect(usage.month == "2026-11")
        #expect(usage.monthInputTokens == 0)
        #expect(usage.monthOutputTokens == 0)
        #expect(usage.lastRun?.at == october31Late)

        let reloaded = AnalysisUsageStore(now: { clock.now })
        reloaded.load(modelContext: ModelContext(container))
        clock.now = october31Late
        reloaded.refreshCurrentMonth()
        #expect(reloaded.usage(for: .openai).monthInputTokens == 900)
    }

    @Test("A later month replaces the totals; an earlier one adds nothing and leaves the last run")
    func laterAndEarlierRecords() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let clock = TestClock(november20)
        let store = AnalysisUsageStore(now: { clock.now })
        store.load(modelContext: context)

        store.record(provider: .google, feature: .adDetection, inputTokens: 100, outputTokens: 10, at: october15, modelContext: context)
        store.record(provider: .google, feature: .adDetection, inputTokens: 300, outputTokens: 30, at: november1Early, modelContext: context)
        #expect(store.usage(for: .google).monthInputTokens == 300)
        #expect(store.usage(for: .google).lastRun?.at == november1Early)

        store.record(provider: .google, feature: .chaptersSummary, inputTokens: 700, outputTokens: 70, at: october16, modelContext: context)

        let usage = store.usage(for: .google)
        #expect(usage.month == "2026-11")
        #expect(usage.monthInputTokens == 300)
        #expect(usage.monthOutputTokens == 30)
        #expect(usage.lastRun?.at == november1Early)
        #expect(usage.lastRun?.feature == "ad_detection")
    }

    @Test("A future-stamped run counts at the clock's time, so later runs this month still add")
    func futureStampIsClampedToNow() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let clock = TestClock(october15)
        let store = AnalysisUsageStore(now: { clock.now })
        store.load(modelContext: context)

        store.record(provider: .google, feature: .adDetection, inputTokens: 100, outputTokens: 10, at: november20, modelContext: context)
        #expect(store.usage(for: .google).month == "2026-10")
        #expect(store.usage(for: .google).lastRun?.at == october15)

        clock.now = october16
        store.record(provider: .google, feature: .adDetection, inputTokens: 50, outputTokens: 5, at: october16, modelContext: context)

        let usage = store.usage(for: .google)
        #expect(usage.month == "2026-10")
        #expect(usage.monthInputTokens == 150)
        #expect(usage.monthOutputTokens == 15)
        #expect(usage.lastRun?.at == october16)
    }

    @Test("Usage recorded while the clock ran a month fast gives way once the clock is corrected")
    func clockCorrectionRecoversTheCurrentMonth() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let clock = TestClock(november20)
        let store = AnalysisUsageStore(now: { clock.now })
        store.load(modelContext: context)
        store.record(provider: .google, feature: .adDetection, inputTokens: 900, outputTokens: 90, at: november20, modelContext: context)

        clock.now = october16
        store.refreshCurrentMonth()
        store.record(provider: .google, feature: .chaptersSummary, inputTokens: 40, outputTokens: 4, at: october16, modelContext: context)

        let usage = store.usage(for: .google)
        #expect(usage.month == "2026-10")
        #expect(usage.monthInputTokens == 40)
        #expect(usage.monthOutputTokens == 4)
        #expect(usage.lastRun?.at == october16)
        #expect(usage.lastRun?.feature == "chapters_summary")
    }

    @Test("Negative counts read as zero and sums saturate")
    func negativeCountsAndSaturation() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let clock = TestClock(october15)
        let store = AnalysisUsageStore(now: { clock.now })
        store.load(modelContext: context)

        store.record(provider: .google, feature: .adDetection, inputTokens: -40, outputTokens: -4, at: october15, modelContext: context)
        #expect(store.usage(for: .google).monthInputTokens == 0)
        #expect(store.usage(for: .google).lastRun?.inputTokens == 0)

        store.record(provider: .google, feature: .adDetection, inputTokens: Int.max, outputTokens: Int.max, at: october15, modelContext: context)
        store.record(provider: .google, feature: .adDetection, inputTokens: 1, outputTokens: 1, at: october15, modelContext: context)

        #expect(store.usage(for: .google).monthInputTokens == Int.max)
        #expect(store.usage(for: .google).monthOutputTokens == Int.max)
    }

    @Test("Usage persists as compact JSON and survives a reload")
    func persistenceAcrossReload() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let clock = TestClock(october16)
        let store = AnalysisUsageStore(now: { clock.now })
        store.load(modelContext: context)
        store.record(provider: .openai, feature: .chaptersSummary, inputTokens: 2_000, outputTokens: 400, at: october16, modelContext: context)

        let stored = try #require(try LocalPreferenceRecord.preference(forKey: "aiServices.usage.openai", modelContext: ModelContext(container)))
        #expect(!stored.value.contains("\n"))
        #expect(try JSONDecoder().decode(AnalysisProviderUsage.self, from: Data(stored.value.utf8)) == store.usage(for: .openai))

        let reloaded = AnalysisUsageStore(now: { clock.now })
        reloaded.load(modelContext: ModelContext(container))
        #expect(reloaded.usage(for: .openai) == store.usage(for: .openai))
        #expect(reloaded.usage(for: .google).lastRun == nil)
    }

    @Test("A failed save records nothing and reports the error")
    func failedSaveRecordsNothing() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        struct SaveFailed: Error {}
        let clock = TestClock(october15)
        let store = AnalysisUsageStore(save: { _ in throw SaveFailed() }, now: { clock.now })
        store.load(modelContext: context)

        let recorded = store.record(provider: .google, feature: .adDetection, inputTokens: 10, outputTokens: 1, at: october15, modelContext: context)

        #expect(!recorded)
        #expect(store.usage(for: .google).lastRun == nil)
        #expect(store.lastErrorMessage != nil)
    }
}

private final class TestClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}
