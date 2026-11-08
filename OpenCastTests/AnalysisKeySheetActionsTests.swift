import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import Security
import SwiftData
import Synchronization
import Testing
@testable import OpenCast

/// What the key sheet's Save, sync switch and Remove do to the tier state,
/// on the real key store over the in-memory Keychain with its faults. Every
/// expectation is also read back from the store's preference.
@MainActor
@Suite("Analysis key sheet actions")
struct AnalysisKeySheetActionsTests {
    private static let day = Date(timeIntervalSince1970: 1_793_000_000)
    private static let yesterday = day.addingTimeInterval(-86_400)
    private static let typed = AnalysisKeyFixtures.key(AnalysisKeyFixtures.googleText)
    private static let other = AnalysisKeyFixtures.key(AnalysisKeyFixtures.replacementText)
    private static let delete = AnalysisProviderKeyStoreError.Operation.delete

    /// Fails one operation on one form, once armed.
    private nonisolated final class FaultSwitch: Sendable {
        private let armed = Mutex<(AnalysisProviderKeyStoreError.Operation, Bool)?>(nil)

        func arm(_ operation: AnalysisProviderKeyStoreError.Operation, synchronizable: Bool) {
            armed.withLock { $0 = (operation, synchronizable) }
        }

        func status(_ operation: AnalysisProviderKeyStoreError.Operation, _ synchronizable: Bool) -> OSStatus? {
            armed.withLock { armed in
                armed.map { $0.0 == operation && $0.1 == synchronizable } == true ? errSecInteractionNotAllowed : nil
            }
        }
    }

    @MainActor
    private final class Stack {
        let faults = FaultSwitch()
        let storage: InMemoryAnalysisProviderKeyStorage
        let keys: AnalysisProviderKeyStore
        let tier = AnalysisKeyTierStore(now: { AnalysisKeySheetActionsTests.day })
        let context: ModelContext

        init(seeded: [AnalysisProvider: (AnalysisProviderKey, syncs: Bool)] = [:]) throws {
            let faults = faults
            storage = InMemoryAnalysisProviderKeyStorage(seeded: seeded, fault: { faults.status($0, $1) })
            keys = AnalysisProviderKeyStore(storage: storage)
            context = ModelContext(try OpenCastModelContainerFactory.make(inMemory: true))
        }

        func actions(_ provider: AnalysisProvider = .google) -> AnalysisKeySheetActions {
            AnalysisKeySheetActions(provider: provider, keys: keys, tier: tier, modelContext: context)
        }

        /// The state as a later launch would read it.
        var persisted: AnalysisKeyTierStore.State {
            let store = AnalysisKeyTierStore()
            store.load(modelContext: context)
            return store.state
        }

        func expectState(_ expected: AnalysisKeyTierStore.State, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(tier.state == expected, sourceLocation: sourceLocation)
            #expect(persisted == expected, sourceLocation: sourceLocation)
        }
    }

    private static func answer(
        _ result: AnalysisTierCheckResult,
        for key: AnalysisProviderKey = typed
    ) -> AnalysisKeyTierStore.Answer {
        AnalysisKeyTierStore.Answer(result: result, keyDigest: key.digest, answeredAt: yesterday)
    }

    // MARK: A Test's answer around Save

    @Test("A typed key's answer is written after Save of that key, with the day Google gave it")
    func answerWrittenAfterSaveOfThatKey() throws {
        let stack = try Stack()

        try stack.actions().save(Self.typed, syncs: true, tested: Self.answer(.freeTier))

        stack.expectState(.freeTier(day: Self.yesterday))
    }

    @Test("A paid key's answer is written too, so its first run does not pay for another check")
    func paidAnswerWrittenAfterSave() throws {
        let stack = try Stack()

        try stack.actions().save(Self.typed, syncs: false, tested: Self.answer(.notFreeTier))

        stack.expectState(.notFreeTier)
    }

    @Test("An inconclusive Test writes nothing: Save leaves the state unknown")
    func inconclusiveAnswerAfterSave() throws {
        let stack = try Stack()
        stack.tier.noteNotFreeTier(modelContext: stack.context)

        try stack.actions().save(Self.typed, syncs: true, tested: Self.answer(.inconclusive))

        stack.expectState(.unknown)
    }

    @Test("An answer for one key is not written after Save of another, and the old state goes")
    func answerNotWrittenAfterSaveOfAnotherKey() throws {
        let stack = try Stack()
        stack.tier.noteNotFreeTier(modelContext: stack.context)

        try stack.actions().save(Self.other, syncs: true, tested: Self.answer(.freeTier, for: Self.typed))

        stack.expectState(.unknown)
    }

    @Test("A failed credential save writes no answer and leaves the state", arguments: [true, false])
    func failedSaveWritesNothing(syncs: Bool) throws {
        let stack = try Stack(seeded: [.google: (Self.other, syncs: false)])
        stack.tier.noteNotFreeTier(modelContext: stack.context)
        // The local form exists, so that write goes through update.
        stack.faults.arm(syncs ? .add : .update, synchronizable: syncs)

        #expect(throws: AnalysisProviderKeyStoreError.self) {
            try stack.actions().save(Self.typed, syncs: syncs, tested: Self.answer(.freeTier))
        }

        stack.expectState(.notFreeTier)
        #expect(try stack.keys.key(for: .google)?.digest == Self.other.digest)
    }

    // MARK: Partial saves

    @Test("Sync off with the synced copy's delete failed saved the key here, so its answer stands")
    func partialSyncOffSave() throws {
        let stack = try Stack(seeded: [.google: (Self.other, syncs: true)])
        stack.tier.noteNotFreeTier(modelContext: stack.context)
        stack.faults.arm(Self.delete, synchronizable: true)

        #expect(throws: AnalysisProviderKeyStoreError.self) {
            try stack.actions().save(Self.typed, syncs: false, tested: Self.answer(.freeTier))
        }

        stack.expectState(.freeTier(day: Self.yesterday))
        #expect(try stack.keys.key(for: .google)?.digest == Self.typed.digest)
    }

    @Test("Sync on with the local delete failed: the tested key is the one in use, so its answer stands")
    func partialSyncOnSaveWithTheSameLocalKey() throws {
        let stack = try Stack(seeded: [.google: (Self.typed, syncs: false)])
        stack.tier.noteNotFreeTier(modelContext: stack.context)
        stack.faults.arm(Self.delete, synchronizable: false)

        #expect(throws: AnalysisProviderKeyStoreError.self) {
            try stack.actions().save(Self.typed, syncs: true, tested: Self.answer(.freeTier))
        }

        stack.expectState(.freeTier(day: Self.yesterday))
    }

    @Test("Sync on with the local delete failed and no local copy: the synced key is in use, so its answer stands")
    func partialSyncOnSaveWithNoLocalCopy() throws {
        let stack = try Stack(seeded: [.google: (Self.other, syncs: true)])
        stack.tier.noteNotFreeTier(modelContext: stack.context)
        stack.faults.arm(Self.delete, synchronizable: false)

        #expect(throws: AnalysisProviderKeyStoreError.self) {
            try stack.actions().save(Self.typed, syncs: true, tested: Self.answer(.freeTier))
        }

        stack.expectState(.freeTier(day: Self.yesterday))
        #expect(try stack.keys.key(for: .google)?.digest == Self.typed.digest)
    }

    @Test("Sync on with the local delete failed and no Test: the key in use changed, so the state goes")
    func partialSyncOnSaveWithNoTest() throws {
        let stack = try Stack(seeded: [.google: (Self.other, syncs: true)])
        stack.tier.noteNotFreeTier(modelContext: stack.context)
        stack.faults.arm(Self.delete, synchronizable: false)

        #expect(throws: AnalysisProviderKeyStoreError.self) {
            try stack.actions().save(Self.typed, syncs: true, tested: nil)
        }

        stack.expectState(.unknown)
    }

    @Test("Sync on with the local delete failed and another local key still winning leaves the state alone")
    func partialSyncOnSaveWithAnotherLocalKey() throws {
        let stack = try Stack(seeded: [.google: (Self.other, syncs: false)])
        stack.tier.noteNotFreeTier(modelContext: stack.context)
        stack.faults.arm(Self.delete, synchronizable: false)

        #expect(throws: AnalysisProviderKeyStoreError.self) {
            try stack.actions().save(Self.typed, syncs: true, tested: Self.answer(.freeTier))
        }

        stack.expectState(.notFreeTier)
        #expect(try stack.keys.key(for: .google)?.digest == Self.other.digest)
    }

    // MARK: Resets

    @Test("Save resets the state")
    func saveResets() throws {
        let stack = try Stack(seeded: [.google: (Self.other, syncs: false)])
        stack.tier.noteFreeTier(modelContext: stack.context)

        try stack.actions().save(Self.typed, syncs: false, tested: nil)

        stack.expectState(.unknown)
    }

    @Test("Remove resets the state")
    func removeResets() throws {
        let stack = try Stack(seeded: [.google: (Self.typed, syncs: true)])
        stack.tier.noteFreeTier(modelContext: stack.context)

        try stack.actions().remove(includingSyncedCopy: true)

        stack.expectState(.unknown)
        #expect(try stack.keys.key(for: .google) == nil)
    }

    @Test("A Remove that failed keeps the key, and so the state")
    func failedRemoveKeepsTheState() throws {
        let stack = try Stack(seeded: [.google: (Self.typed, syncs: false)])
        stack.tier.noteFreeTier(modelContext: stack.context)
        stack.faults.arm(Self.delete, synchronizable: false)

        #expect(throws: AnalysisProviderKeyStoreError.self) {
            try stack.actions().remove(includingSyncedCopy: false)
        }

        stack.expectState(.freeTier(day: Self.day))
    }

    @Test("Sync off resets the state")
    func syncOffResets() throws {
        let stack = try Stack(seeded: [.google: (Self.typed, syncs: true)])
        stack.tier.noteFreeTier(modelContext: stack.context)

        try stack.actions().setSyncs(false, tested: nil)

        stack.expectState(.unknown)
    }

    @Test("A sync-off that could not delete the synced copy still resets the state")
    func partialSyncOffResets() throws {
        let stack = try Stack(seeded: [.google: (Self.typed, syncs: true)])
        stack.tier.noteFreeTier(modelContext: stack.context)
        stack.faults.arm(Self.delete, synchronizable: true)

        #expect(throws: AnalysisProviderKeyStoreError.self) {
            try stack.actions().setSyncs(false, tested: nil)
        }

        stack.expectState(.unknown)
    }

    @Test("Sync on keeps the same key in use, whole or partial, so a paid key pays for no second check")
    func syncOnKeepsTheState() throws {
        let whole = try Stack(seeded: [.google: (Self.typed, syncs: false)])
        whole.tier.noteNotFreeTier(modelContext: whole.context)
        try whole.actions().setSyncs(true, tested: nil)
        whole.expectState(.notFreeTier)

        let partial = try Stack(seeded: [.google: (Self.typed, syncs: false)])
        partial.tier.noteNotFreeTier(modelContext: partial.context)
        partial.faults.arm(Self.delete, synchronizable: false)
        #expect(throws: AnalysisProviderKeyStoreError.self) {
            try partial.actions().setSyncs(true, tested: nil)
        }
        partial.expectState(.notFreeTier)
    }

    @Test("Another provider's key never touches the Google key's state")
    func anotherProvider() throws {
        let openAI = AnalysisKeyFixtures.key(AnalysisKeyFixtures.openAIText)
        let stack = try Stack()
        stack.tier.noteFreeTier(modelContext: stack.context)

        try stack.actions(.openai).save(openAI, syncs: true, tested: nil)
        try stack.actions(.openai).setSyncs(false, tested: nil)
        try stack.actions(.openai).remove(includingSyncedCopy: true)

        stack.expectState(.freeTier(day: Self.day))
    }

    // MARK: The saved key's Test

    @Test("A saved key's answer is written while that key stands, and never once it changed or went")
    func savedKeyAnswer() throws {
        let stack = try Stack(seeded: [.google: (Self.typed, syncs: false)])

        stack.actions().applyTierAnswer(Self.answer(.freeTier))
        stack.expectState(.freeTier(day: Self.yesterday))

        stack.tier.reset(modelContext: stack.context)
        stack.storage.place(AnalysisKeyFixtures.bytes(of: Self.other), provider: .google, synchronizable: false)
        stack.actions().applyTierAnswer(Self.answer(.freeTier))
        stack.expectState(.unknown)

        stack.storage.place(nil, provider: .google, synchronizable: false)
        stack.actions().applyTierAnswer(Self.answer(.notFreeTier))
        stack.expectState(.unknown)
    }
}
