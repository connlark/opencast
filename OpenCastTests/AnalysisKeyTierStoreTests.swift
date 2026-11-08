import Foundation
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Analysis key tier store")
struct AnalysisKeyTierStoreTests {
    private static let day = Date(timeIntervalSince1970: 1_793_000_000)

    private func makeContext() throws -> ModelContext {
        ModelContext(try OpenCastModelContainerFactory.make(inMemory: true))
    }

    private func reloaded(_ context: ModelContext) -> AnalysisKeyTierStore {
        let store = AnalysisKeyTierStore()
        store.load(modelContext: context)
        return store
    }

    @Test("The preference key stays stable")
    func preferenceKey() {
        #expect(AnalysisKeyTierStore.preferenceKey == "aiServices.keyTier.google")
    }

    @Test("It starts unknown, with nothing stored")
    func startsUnknown() throws {
        #expect(AnalysisKeyTierStore().state == .unknown)
        #expect(reloaded(try makeContext()).state == .unknown)
    }

    @Test("A free-tier answer keeps the day Google said so, across a reload")
    func freeTierKeepsTheDay() throws {
        let context = try makeContext()
        let store = AnalysisKeyTierStore(now: { Self.day })

        store.noteFreeTier(modelContext: context)

        #expect(store.state == .freeTier(day: Self.day))
        #expect(reloaded(context).state == .freeTier(day: Self.day))
    }

    @Test("A day the caller held is the one written, not the time of the write")
    func freeTierTakesTheDayItIsGiven() throws {
        let context = try makeContext()
        let yesterday = Self.day.addingTimeInterval(-86_400)
        let store = AnalysisKeyTierStore(now: { Self.day })

        store.noteFreeTier(day: yesterday, modelContext: context)

        #expect(store.state == .freeTier(day: yesterday))
        #expect(reloaded(context).state == .freeTier(day: yesterday))
    }

    @Test("Each transition stands, and the last one is what a reload reads")
    func transitions() throws {
        let context = try makeContext()
        let store = AnalysisKeyTierStore(now: { Self.day })

        store.noteNotFreeTier(modelContext: context)
        #expect(store.state == .notFreeTier)
        #expect(reloaded(context).state == .notFreeTier)

        store.noteFreeTier(modelContext: context)
        #expect(store.state == .freeTier(day: Self.day))
        #expect(reloaded(context).state == .freeTier(day: Self.day))

        store.reset(modelContext: context)
        #expect(store.state == .unknown)
        #expect(reloaded(context).state == .unknown)
    }

    @Test("Free tier gives way to not free tier, and not free tier to unknown, across a reload")
    func freeToNotFreeToUnknown() throws {
        let context = try makeContext()
        let store = AnalysisKeyTierStore(now: { Self.day })
        store.noteFreeTier(modelContext: context)

        store.noteNotFreeTier(modelContext: context)
        #expect(store.state == .notFreeTier)
        #expect(reloaded(context).state == .notFreeTier)

        store.reset(modelContext: context)
        #expect(store.state == .unknown)
        #expect(reloaded(context).state == .unknown)
    }

    @Test("A value it cannot read is unknown, which costs one check and never a route")
    func unreadableValue() throws {
        let context = try makeContext()
        for value in ["", "free_tier", "free_tier:yesterday", "paid", "true"] {
            try LocalPreferenceRecord.upsert(key: AnalysisKeyTierStore.preferenceKey, value: value, modelContext: context)
            try context.save()
            #expect(reloaded(context).state == .unknown, "\(value)")
        }
    }

    @Test("A failed save stands for the session only")
    func failedSave() throws {
        struct SaveFailed: Error {}
        let context = try makeContext()
        let store = AnalysisKeyTierStore(save: { _ in throw SaveFailed() })

        store.noteNotFreeTier(modelContext: context)

        #expect(store.state == .notFreeTier)
        #expect(reloaded(context).state == .unknown)
    }

    // MARK: An answer lands only on the key it was given for

    private static let key = Data("the-key-digest".utf8)
    private static let otherKey = Data("another-key-digest".utf8)

    @Test("An answer is written when the saved key is still the one it was given for")
    func answerForTheSavedKey() throws {
        let context = try makeContext()
        let store = AnalysisKeyTierStore(now: { Self.day })

        store.apply(.init(result: .freeTier, keyDigest: Self.key, answeredAt: Self.day), savedKeyDigest: Self.key, modelContext: context)
        #expect(store.state == .freeTier(day: Self.day))

        store.apply(.init(result: .notFreeTier, keyDigest: Self.key, answeredAt: Self.day), savedKeyDigest: Self.key, modelContext: context)
        #expect(store.state == .notFreeTier)
    }

    @Test("The mark's day is the day Google answered, not the day the answer was applied")
    func answerKeepsItsOwnDay() throws {
        let context = try makeContext()
        let yesterday = Self.day.addingTimeInterval(-86_400)
        let store = AnalysisKeyTierStore(now: { Self.day })

        store.apply(.init(result: .freeTier, keyDigest: Self.key, answeredAt: yesterday), savedKeyDigest: Self.key, modelContext: context)

        #expect(store.state == .freeTier(day: yesterday))
        #expect(reloaded(context).state == .freeTier(day: yesterday))
    }

    @Test("An answer for one key is never written after the saved key changed, went or could not be read")
    func answerForAnotherKey() throws {
        let context = try makeContext()
        let store = AnalysisKeyTierStore()

        store.apply(.init(result: .freeTier, keyDigest: Self.key, answeredAt: Self.day), savedKeyDigest: Self.otherKey, modelContext: context)
        #expect(store.state == .unknown)

        store.apply(.init(result: .notFreeTier, keyDigest: Self.key, answeredAt: Self.day), savedKeyDigest: nil, modelContext: context)
        #expect(store.state == .unknown)
        #expect(reloaded(context).state == .unknown)
    }

    @Test("An inconclusive answer writes nothing and leaves what was there")
    func inconclusiveWritesNothing() throws {
        let context = try makeContext()
        let store = AnalysisKeyTierStore(now: { Self.day })
        store.noteFreeTier(modelContext: context)

        store.apply(.init(result: .inconclusive, keyDigest: Self.key, answeredAt: Self.day), savedKeyDigest: Self.key, modelContext: context)

        #expect(store.state == .freeTier(day: Self.day))
    }
}
