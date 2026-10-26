import CryptoKit
import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import Security
import Testing
@testable import OpenCast

@MainActor
@Suite("Analysis provider key store")
struct AnalysisProviderKeyStoreTests {
    private let google = AnalysisKeyFixtures.googleText
    private let replacement = AnalysisKeyFixtures.replacementText
    private let synced = kSecAttrAccessibleAfterFirstUnlock as String
    private let local = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String

    // MARK: - Both storages

    /// The forms a test starts from: `a` is this device's local key, `b`
    /// a synced key (this device's or another device's).
    enum Start: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case empty, local, synced, both
        var testDescription: String { rawValue }
    }

    enum Operation: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case saveLocal, saveSynced, syncOff, syncOn, removeEverywhere, removeHere
        var testDescription: String { rawValue }
    }

    /// The Keychain storage, and its in-memory twin: every case below runs
    /// against both.
    enum Backend: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case keychain, inMemory
        var testDescription: String { rawValue }
    }

    /// The forms present: local bytes and synced bytes.
    struct Forms: Equatable, CustomStringConvertible {
        var local: String?
        var synced: String?
        var description: String { "local \(local == nil ? "none" : "set"), synced \(synced == nil ? "none" : "set")" }
    }

    /// One storage under test, with its fault script, and its Google items
    /// staged and read behind its back, as another device or process would.
    struct Bench: Sendable {
        let storage: any AnalysisProviderKeyStoring
        let faults: AnalysisKeychainFaultScript
        let place: @Sendable (String?, _ synchronizable: Bool) -> Void
        let forms: @Sendable () -> Forms
        let cleanUp: @Sendable () -> Void

        init(_ backend: Backend) {
            let faults = AnalysisKeychainFaultScript()
            self.faults = faults
            switch backend {
            case .keychain:
                let service = AnalysisKeychainTestService()
                storage = service.storage(fault: faults.fault)
                place = { text, synchronizable in
                    service.delete(account: "google", synchronizable: synchronizable)
                    if let text {
                        service.add(account: "google", text: text, synchronizable: synchronizable)
                    }
                }
                forms = {
                    let items = service.items(account: "google")
                    return Forms(
                        local: items.first { !$0.synchronizable }?.data.map { String(decoding: $0, as: UTF8.self) },
                        synced: items.first { $0.synchronizable }?.data.map { String(decoding: $0, as: UTF8.self) }
                    )
                }
                cleanUp = { service.deleteAll() }
            case .inMemory:
                let memory = InMemoryAnalysisProviderKeyStorage(fault: faults.fault)
                storage = memory
                place = { text, synchronizable in
                    memory.place(text.map { Data($0.utf8) }, provider: .google, synchronizable: synchronizable)
                }
                forms = {
                    let stored = memory.stored(.google)
                    return Forms(
                        local: stored.local.map { String(decoding: $0, as: UTF8.self) },
                        synced: stored.synced.map { String(decoding: $0, as: UTF8.self) }
                    )
                }
                cleanUp = {}
            }
        }

        func stage(_ start: Start) {
            if start == .local || start == .both {
                place(AnalysisProviderKeyStoreTests.a, false)
            }
            if start == .synced || start == .both {
                place(AnalysisProviderKeyStoreTests.b, true)
            }
        }
    }

    fileprivate nonisolated static let a = AnalysisKeyFixtures.googleText
    fileprivate nonisolated static let b = AnalysisKeyFixtures.replacementText
    private nonisolated static let k = AnalysisKeyFixtures.openAIText

    /// CONTRACT 6R as folded: what each operation leaves from each start.
    private static func expected(_ operation: Operation, from start: Start) -> Forms? {
        let local = start == .local || start == .both ? a : nil
        let synced = start == .synced || start == .both ? b : nil
        switch operation {
        case .saveLocal:
            // Deletes the synced form only when this device was using it.
            return Forms(local: k, synced: local == nil ? nil : synced)
        case .saveSynced:
            return Forms(local: nil, synced: k)
        case .syncOff:
            guard let current = local ?? synced else { return nil }
            return local == nil ? Forms(local: current, synced: nil) : Forms(local: local, synced: synced)
        case .syncOn:
            guard let current = local ?? synced else { return nil }
            return Forms(local: nil, synced: current)
        case .removeEverywhere:
            return Forms(local: nil, synced: nil)
        case .removeHere:
            return Forms(local: nil, synced: synced)
        }
    }

    private func run(_ operation: Operation, on storage: any AnalysisProviderKeyStoring) throws(AnalysisProviderKeyStoreError) {
        switch operation {
        case .saveLocal: try storage.save(AnalysisKeyFixtures.key(Self.k), provider: .google, syncs: false)
        case .saveSynced: try storage.save(AnalysisKeyFixtures.key(Self.k), provider: .google, syncs: true)
        case .syncOff: try storage.setSyncs(false, provider: .google)
        case .syncOn: try storage.setSyncs(true, provider: .google)
        case .removeEverywhere: try storage.remove(provider: .google, includingSyncedCopy: true)
        case .removeHere: try storage.remove(provider: .google, includingSyncedCopy: false)
        }
    }

    /// Both forms the twin holds, as text.
    private func forms(_ storage: InMemoryAnalysisProviderKeyStorage) -> Forms {
        let stored = storage.stored(.google)
        return Forms(
            local: stored.local.map { String(decoding: $0, as: UTF8.self) },
            synced: stored.synced.map { String(decoding: $0, as: UTF8.self) }
        )
    }

    /// The read rule: the local form when present, else the synced one.
    private func expectReadRule(_ storage: any AnalysisProviderKeyStoring, _ forms: Forms, _ backend: Backend) throws {
        let shown = forms.local ?? forms.synced
        #expect(try AnalysisKeyFixtures.bytes(of: storage.key(for: .google)) == shown.map { Data($0.utf8) }, "\(backend)")
        let presence: AnalysisKeyPresence = forms.local != nil ? .saved(synced: false)
            : forms.synced != nil ? .saved(synced: true) : AnalysisKeyPresence.none
        #expect(try storage.presence(for: .google) == presence, "\(backend)")
        #expect(try storage.syncedCopyExists(for: .google) == (forms.synced != nil), "\(backend)")
    }

    @Test("The default service name stays stable")
    func defaultServiceStaysStable() {
        #expect(KeychainAnalysisProviderKeyStorage.defaultService == "com.connor.opencast.analysis-provider-keys")
    }

    @Test("Every operation from every starting form leaves the forms the contract names", arguments: Start.allCases, Operation.allCases)
    func operationTable(start: Start, operation: Operation) throws {
        for backend in Backend.allCases {
            let bench = Bench(backend)
            defer { bench.cleanUp() }
            bench.stage(start)

            guard let expected = Self.expected(operation, from: start) else {
                #expect(throws: AnalysisProviderKeyStoreError.notSaved) {
                    try run(operation, on: bench.storage)
                }
                #expect(bench.forms() == Forms(), "\(backend)")
                continue
            }
            try run(operation, on: bench.storage)
            #expect(bench.forms() == expected, "\(backend)")
            try expectReadRule(bench.storage, expected, backend)
        }
    }

    @Test("Re-adding identical bytes in either form updates in place", arguments: Backend.allCases)
    func identicalBytesReAdd(backend: Backend) throws {
        let bench = Bench(backend)
        defer { bench.cleanUp() }
        let storage = bench.storage
        for syncs in [true, true, false, false] {
            try storage.save(AnalysisKeyFixtures.key(Self.a), provider: .google, syncs: syncs)
            #expect(bench.forms() == (syncs ? Forms(local: nil, synced: Self.a) : Forms(local: Self.a, synced: nil)))
            #expect(try storage.presence(for: .google) == .saved(synced: syncs))
        }
        // Another device re-adds the same bytes as a synced key while this one is local.
        bench.place(Self.a, true)
        try storage.save(AnalysisKeyFixtures.key(Self.a), provider: .google, syncs: false)
        #expect(bench.forms() == Forms(local: Self.a, synced: Self.a))
        try storage.setSyncs(true, provider: .google)
        #expect(bench.forms() == Forms(local: nil, synced: Self.a))
    }

    @Test("A failure at the first call changes nothing", arguments: Backend.allCases)
    func firstCallFailureChangesNothing(backend: Backend) throws {
        for (start, operation, failing) in [
            (Start.synced, Operation.saveLocal, AnalysisProviderKeyStoreError.Operation.add),
            (.local, .saveSynced, .add),
            (.synced, .syncOff, .add),
            (.local, .syncOn, .add),
            (.both, .removeEverywhere, .delete),
            (.both, .removeHere, .delete),
        ] {
            let bench = Bench(backend)
            defer { bench.cleanUp() }
            bench.stage(start)
            let before = bench.forms()
            bench.faults.fail(failing, with: errSecInteractionNotAllowed, times: 1)

            #expect(throws: AnalysisProviderKeyStoreError.keychain(operation: failing, status: errSecInteractionNotAllowed)) {
                try run(operation, on: bench.storage)
            }
            #expect(bench.forms() == before, "\(operation) from \(start)")
        }
    }

    @Test("A failure at the second call leaves what the contract's failure table names, and a retry finishes", arguments: Backend.allCases)
    func secondCallFailureThenRetry(backend: Backend) throws {
        // (start, operation, the form whose delete fails, left behind, after a retry)
        let cases: [(Start, Operation, Bool, Forms, Forms)] = [
            (.synced, .saveLocal, true, Forms(local: Self.k, synced: Self.b), Forms(local: Self.k, synced: Self.b)),
            (.local, .saveSynced, false, Forms(local: Self.a, synced: Self.k), Forms(local: nil, synced: Self.k)),
            (.synced, .syncOff, true, Forms(local: Self.b, synced: Self.b), Forms(local: Self.b, synced: Self.b)),
            (.local, .syncOn, false, Forms(local: Self.a, synced: Self.a), Forms(local: nil, synced: Self.a)),
            (.both, .removeEverywhere, false, Forms(local: Self.a, synced: nil), Forms(local: nil, synced: nil)),
        ]
        for (start, operation, failingForm, left, retried) in cases {
            let bench = Bench(backend)
            defer { bench.cleanUp() }
            bench.stage(start)
            bench.faults.fail(.delete, synchronizable: failingForm, with: errSecInteractionNotAllowed, times: 1)

            #expect(throws: AnalysisProviderKeyStoreError.keychain(operation: .delete, status: errSecInteractionNotAllowed)) {
                try run(operation, on: bench.storage)
            }
            #expect(bench.forms() == left, "\(operation) from \(start) after the failure")
            try expectReadRule(bench.storage, left, backend)

            // Retrying the operation cannot delete a synced copy left by a
            // sync-off (the local key already wins): removing the synced copy
            // can, and keeps the local key.
            try run(operation, on: bench.storage)
            #expect(bench.forms() == retried, "\(operation) from \(start) after the retry")
            if retried.local != nil, retried.synced != nil {
                try bench.storage.removeSyncedCopy(provider: .google)
                #expect(bench.forms() == Forms(local: retried.local, synced: nil), "\(operation) from \(start) after removing the synced copy")
            }
        }
    }

    @Test("Removing the synced copy keeps the local key, and never runs without one", arguments: Backend.allCases)
    func removeSyncedCopyNeedsALocalKey(backend: Backend) throws {
        let syncedOnly = Bench(backend)
        defer { syncedOnly.cleanUp() }
        syncedOnly.stage(.synced)
        #expect(throws: AnalysisProviderKeyStoreError.notSaved) {
            try syncedOnly.storage.removeSyncedCopy(provider: .google)
        }
        #expect(syncedOnly.forms() == Forms(local: nil, synced: Self.b))

        let both = Bench(backend)
        defer { both.cleanUp() }
        both.stage(.both)
        both.faults.fail(.delete, synchronizable: true, with: errSecNotAvailable, times: 1)
        #expect(throws: AnalysisProviderKeyStoreError.keychain(operation: .delete, status: errSecNotAvailable)) {
            try both.storage.removeSyncedCopy(provider: .google)
        }
        #expect(both.forms() == Forms(local: Self.a, synced: Self.b))
        try both.storage.removeSyncedCopy(provider: .google)
        #expect(both.forms() == Forms(local: Self.a, synced: nil))
        try both.storage.removeSyncedCopy(provider: .google)
        #expect(both.forms() == Forms(local: Self.a, synced: nil))
    }

    @Test("Removing everywhere deletes the synced copy first, so a failure there leaves the key this device showed", arguments: Backend.allCases)
    func removeFailureNeverShowsAnotherDevicesKey(backend: Backend) throws {
        let bench = Bench(backend)
        defer { bench.cleanUp() }
        bench.stage(.both)
        bench.faults.fail(.delete, synchronizable: true, with: errSecNotAvailable, times: 1)

        #expect(throws: AnalysisProviderKeyStoreError.keychain(operation: .delete, status: errSecNotAvailable)) {
            try bench.storage.remove(provider: .google, includingSyncedCopy: true)
        }
        #expect(try AnalysisKeyFixtures.bytes(of: bench.storage.key(for: .google)) == Data(Self.a.utf8))
    }

    @Test("A synced key another device writes between this device's write and its delete goes with the delete (documented)", arguments: Backend.allCases)
    func concurrentSyncedWriteIsLostToTheDelete(backend: Backend) throws {
        let bench = Bench(backend)
        defer { bench.cleanUp() }
        bench.stage(.synced)
        // Another device replaces the synced key just before this device's
        // delete of the synced form: the delete names the form, not the bytes.
        let place = bench.place
        bench.faults.beforeCall { operation, synchronizable in
            if operation == .delete, synchronizable {
                place(Self.k, true)
            }
        }

        try bench.storage.setSyncs(false, provider: .google)

        #expect(bench.forms() == Forms(local: Self.b, synced: nil))
    }

    @Test("An unreadable local item throws instead of falling back to a synced key", arguments: Backend.allCases)
    func unreadableLocalNeverFallsBack(backend: Backend) throws {
        let bench = Bench(backend)
        defer { bench.cleanUp() }
        bench.stage(.both)
        bench.faults.fail(.read, synchronizable: false, with: errSecInteractionNotAllowed)

        #expect(throws: AnalysisProviderKeyStoreError.keychain(operation: .read, status: errSecInteractionNotAllowed)) {
            try bench.storage.key(for: .google)
        }
        #expect(throws: AnalysisProviderKeyStoreError.keychain(operation: .read, status: errSecInteractionNotAllowed)) {
            try bench.storage.presence(for: .google)
        }
        // The synced copy alone still reads.
        #expect(try bench.storage.syncedCopyExists(for: .google))
    }

    @Test("An update that finds nothing retries the add once, then fails without deleting the other form", arguments: Backend.allCases)
    func vanishedDuplicateRetriesOnceThenKeepsTheKey(backend: Backend) throws {
        let bench = Bench(backend)
        defer { bench.cleanUp() }
        bench.stage(.local)

        bench.faults.fail(.add, synchronizable: true, with: errSecDuplicateItem)
        bench.faults.fail(.update, synchronizable: true, with: errSecItemNotFound)
        #expect(throws: AnalysisProviderKeyStoreError.keychain(operation: .add, status: errSecDuplicateItem)) {
            try bench.storage.save(AnalysisKeyFixtures.key(Self.k), provider: .google, syncs: true)
        }
        #expect(bench.forms() == Forms(local: Self.a, synced: nil))
    }

    @Test("An update that finds nothing succeeds when the one retried add does", arguments: Backend.allCases)
    func vanishedDuplicateRetrySucceeds(backend: Backend) throws {
        let bench = Bench(backend)
        defer { bench.cleanUp() }

        bench.faults.fail(.add, synchronizable: true, with: errSecDuplicateItem, times: 1)
        bench.faults.fail(.update, synchronizable: true, with: errSecItemNotFound, times: 1)
        try bench.storage.save(AnalysisKeyFixtures.key(Self.a), provider: .google, syncs: true)

        #expect(bench.forms() == Forms(local: nil, synced: Self.a))
    }

    @Test("Stored bytes that are not a key read as unreadable", arguments: Backend.allCases)
    func undecodableBytesAreUnreadable(backend: Backend) throws {
        let bench = Bench(backend)
        defer { bench.cleanUp() }
        bench.place("   ", false)

        #expect(throws: AnalysisProviderKeyStoreError.unreadable) {
            try bench.storage.key(for: .google)
        }
        #expect(try bench.storage.presence(for: .google) == .saved(synced: false))
    }

    @Test("A Keychain failure carries its operation and status", arguments: Backend.allCases)
    func keychainFailuresCarryOperationAndStatus(backend: Backend) {
        let bench = Bench(backend)
        defer { bench.cleanUp() }
        bench.faults.fail(.read, with: errSecNotAvailable)

        #expect(throws: AnalysisProviderKeyStoreError.keychain(operation: .read, status: errSecNotAvailable)) {
            try bench.storage.presence(for: .google)
        }
        #expect(throws: AnalysisProviderKeyStoreError.keychain(operation: .read, status: errSecNotAvailable)) {
            try bench.storage.key(for: .google)
        }
    }

    // MARK: - Keychain only

    @Test("Each form is written with its own attributes, and every switch rewrites them")
    func attributeSetsFollowTheForm() throws {
        let service = AnalysisKeychainTestService()
        defer { service.deleteAll() }
        let storage = service.storage()

        try storage.save(AnalysisKeyFixtures.key(Self.a), provider: .google, syncs: true)
        #expect(service.items(account: "google").map(\.synchronizable) == [true])
        #expect(service.items(account: "google").map(\.accessible) == [synced])

        try storage.setSyncs(false, provider: .google)
        #expect(service.items(account: "google").map(\.synchronizable) == [false])
        #expect(service.items(account: "google").map(\.accessible) == [local])
        #expect(service.items(account: "google").map(\.data) == [Data(Self.a.utf8)])

        try storage.setSyncs(true, provider: .google)
        #expect(service.items(account: "google").map(\.synchronizable) == [true])
        #expect(service.items(account: "google").map(\.accessible) == [synced])

        try storage.save(AnalysisKeyFixtures.key(Self.k), provider: .google, syncs: false)
        #expect(service.items(account: "google").map(\.synchronizable) == [false])
        #expect(service.items(account: "google").map(\.accessible) == [local])
        #expect(service.items(account: "google").map(\.data) == [Data(Self.k.utf8)])
    }

    // MARK: - Observable store

    @Test("The store reads nothing until refreshed, then publishes every provider")
    func storeRefreshPublishesPresences() async throws {
        let storage = InMemoryAnalysisProviderKeyStorage(seeded: [.openai: (AnalysisKeyFixtures.key(google), syncs: false)])
        let store = AnalysisProviderKeyStore(storage: storage)

        #expect(store.presences == [.google: AnalysisKeyPresence.none, .openai: AnalysisKeyPresence.none])
        #expect(store.syncedCopyStatus(.google) == .unknown)
        #expect(!store.hasSavedKey)

        await store.refreshPresences()

        #expect(store.presence(for: .openai) == .saved(synced: false))
        #expect(store.presence(for: .google) == AnalysisKeyPresence.none)
        #expect(store.syncedCopyStatus(.openai) == .absent)
        #expect(store.hasSavedKey)
    }

    @Test("Mutations publish their own result")
    func storeMutationsPublishTheirResult() throws {
        let store = AnalysisProviderKeyStore(storage: InMemoryAnalysisProviderKeyStorage())

        try store.save(AnalysisKeyFixtures.key(google), provider: .google, syncs: true)
        #expect(store.presence(for: .google) == .saved(synced: true))
        #expect(store.syncedCopyStatus(.google) == .present)
        #expect(store.hasSavedKey)

        try store.setSyncs(false, provider: .google)
        #expect(store.presence(for: .google) == .saved(synced: false))
        #expect(store.syncedCopyStatus(.google) == .absent)
        #expect(try AnalysisKeyFixtures.bytes(of: store.key(for: .google)) == Data(google.utf8))

        try store.remove(provider: .google, includingSyncedCopy: true)
        #expect(store.presence(for: .google) == AnalysisKeyPresence.none)
        #expect(!store.hasSavedKey)

        #expect(throws: AnalysisProviderKeyStoreError.notSaved) {
            try store.setSyncs(true, provider: .openai)
        }
        #expect(store.presence(for: .openai) == AnalysisKeyPresence.none)
        #expect(store.syncedCopyStatus(.openai) == .absent)
    }

    @Test("A failed read keeps the provider's last presence, says so, and never makes a synced copy absent")
    func storeKeepsLastPresenceOnFailedRead() async throws {
        let service = AnalysisKeychainTestService()
        defer { service.deleteAll() }
        let faults = AnalysisKeychainFaultScript()
        let store = AnalysisProviderKeyStore(storage: service.storage(fault: faults.fault))
        try store.save(AnalysisKeyFixtures.key(google), provider: .google, syncs: true)
        await store.refreshPresences()
        #expect(store.presence(for: .google) == .saved(synced: true))
        #expect(!store.lastReadFailed(.google))

        faults.fail(.read, with: errSecInteractionNotAllowed)
        service.delete(account: "google", synchronizable: true)
        await store.refreshPresences()

        #expect(store.presence(for: .google) == .saved(synced: true))
        #expect(store.lastReadFailed(.google))
        #expect(store.syncedCopyStatus(.google) == .unknown)

        faults.clear()
        await store.refreshPresences()
        #expect(store.presence(for: .google) == AnalysisKeyPresence.none)
        #expect(!store.lastReadFailed(.google))
        #expect(store.syncedCopyStatus(.google) == .absent)
    }

    @Test("A local-only Remove whose read fails keeps the last presence and says the status is unavailable")
    func localRemoveWithFailedReadNeverShowsNoKey() async throws {
        let faults = AnalysisKeychainFaultScript()
        let storage = InMemoryAnalysisProviderKeyStorage(
            seeded: [.google: (AnalysisKeyFixtures.key(google), syncs: false)],
            fault: faults.fault
        )
        let store = AnalysisProviderKeyStore(storage: storage)
        await store.refreshPresences()
        #expect(!store.removalIncludesSyncedCopy(.google))

        // Another device's synced key arrives, unseen, and reads start failing.
        storage.place(Data(replacement.utf8), provider: .google, synchronizable: true)
        faults.fail(.read, with: errSecInteractionNotAllowed)
        try store.remove(provider: .google, includingSyncedCopy: store.removalIncludesSyncedCopy(.google))

        #expect(forms(storage) == Forms(local: nil, synced: replacement))
        #expect(store.presence(for: .google) == .saved(synced: false))
        #expect(store.lastReadFailed(.google))
        #expect(store.syncedCopyStatus(.google) == .unknown)
        #expect(store.removalIncludesSyncedCopy(.google))

        faults.clear()
        await store.refreshPresences()
        #expect(store.presence(for: .google) == .saved(synced: true))
        #expect(!store.lastReadFailed(.google))
    }

    @Test("A failed synced-copy read keeps a successful local reading, and Remove then includes the synced copy")
    func failedSyncedReadKeepsTheLocalReading() async throws {
        let faults = AnalysisKeychainFaultScript()
        let storage = InMemoryAnalysisProviderKeyStorage(fault: faults.fault)
        storage.place(Data(google.utf8), provider: .google, synchronizable: false)
        storage.place(Data(replacement.utf8), provider: .google, synchronizable: true)
        let store = AnalysisProviderKeyStore(storage: storage)
        faults.fail(.read, synchronizable: true, with: errSecInteractionNotAllowed)

        await store.refreshPresences()

        #expect(store.presence(for: .google) == .saved(synced: false))
        #expect(!store.lastReadFailed(.google))
        #expect(store.syncedCopyStatus(.google) == .unknown)
        #expect(store.removalIncludesSyncedCopy(.google))
    }

    @Test("Turning sync off that stops after its local write keeps the key; the synced copy beside it is offered, and its removal fails, then works")
    func incompleteSyncOffOffersTheSyncedCopy() async throws {
        let faults = AnalysisKeychainFaultScript()
        let storage = InMemoryAnalysisProviderKeyStorage(
            seeded: [.google: (AnalysisKeyFixtures.key(google), syncs: true)],
            fault: faults.fault
        )
        let store = AnalysisProviderKeyStore(storage: storage)
        await store.refreshPresences()
        faults.fail(.delete, synchronizable: true, with: errSecNotAvailable, times: 2)

        #expect(throws: AnalysisProviderKeyStoreError.keychain(operation: .delete, status: errSecNotAvailable)) {
            try store.setSyncs(false, provider: .google)
        }
        #expect(forms(storage) == Forms(local: google, synced: google))
        #expect(store.presence(for: .google) == .saved(synced: false))
        #expect(store.syncedCopyStatus(.google) == .present)
        #expect(store.syncedCopyBesideLocalKey(for: .google))

        // The switch again cannot remove it: the local key already wins.
        try store.setSyncs(false, provider: .google)
        #expect(forms(storage) == Forms(local: google, synced: google))
        #expect(store.syncedCopyBesideLocalKey(for: .google))

        #expect(throws: AnalysisProviderKeyStoreError.keychain(operation: .delete, status: errSecNotAvailable)) {
            try store.removeSyncedCopy(provider: .google)
        }
        #expect(forms(storage) == Forms(local: google, synced: google))
        #expect(store.syncedCopyBesideLocalKey(for: .google))

        try store.removeSyncedCopy(provider: .google)
        #expect(forms(storage) == Forms(local: google, synced: nil))
        #expect(!store.syncedCopyBesideLocalKey(for: .google))
        #expect(store.presence(for: .google) == .saved(synced: false))
        #expect(store.syncedCopyStatus(.google) == .absent)
    }

    @Test("A save with sync off from a synced key that stops after its write leaves the synced copy offered; a synced save replaces both")
    func incompleteLocalSaveOffersTheSyncedCopy() async throws {
        let faults = AnalysisKeychainFaultScript()
        let storage = InMemoryAnalysisProviderKeyStorage(
            seeded: [.google: (AnalysisKeyFixtures.key(google), syncs: true)],
            fault: faults.fault
        )
        let store = AnalysisProviderKeyStore(storage: storage)
        await store.refreshPresences()
        faults.fail(.delete, synchronizable: true, with: errSecNotAvailable, times: 1)

        do throws(AnalysisProviderKeyStoreError) {
            try store.save(AnalysisKeyFixtures.key(replacement), provider: .google, syncs: false)
            Issue.record("The save should have failed at its delete")
        } catch {
            #expect(error.savedLocallyLeavingSyncedCopy(syncs: false))
        }
        #expect(forms(storage) == Forms(local: replacement, synced: google))
        #expect(store.syncedCopyBesideLocalKey(for: .google))

        try store.save(AnalysisKeyFixtures.key(replacement), provider: .google, syncs: true)
        #expect(forms(storage) == Forms(local: nil, synced: replacement))
        #expect(!store.syncedCopyBesideLocalKey(for: .google))
    }

    @Test("A replacement key whose write fails beside a leftover synced copy saved nothing, and says so")
    func failedReplacementWriteSavedNothing() async throws {
        let faults = AnalysisKeychainFaultScript()
        let storage = InMemoryAnalysisProviderKeyStorage(fault: faults.fault)
        storage.place(Data(google.utf8), provider: .google, synchronizable: false)
        storage.place(Data(google.utf8), provider: .google, synchronizable: true)
        let store = AnalysisProviderKeyStore(storage: storage)
        await store.refreshPresences()
        #expect(store.syncedCopyBesideLocalKey(for: .google))
        faults.fail(.update, synchronizable: false, with: errSecNotAvailable, times: 1)

        do throws(AnalysisProviderKeyStoreError) {
            try store.save(AnalysisKeyFixtures.key(replacement), provider: .google, syncs: false)
            Issue.record("The replacement's write should have failed")
        } catch {
            #expect(error == .keychain(operation: .update, status: errSecNotAvailable))
            #expect(!error.savedLocallyLeavingSyncedCopy(syncs: false))
        }
        #expect(forms(storage) == Forms(local: google, synced: google))
    }

    @Test("Only a failed delete after a write with sync off counts as saved here")
    func saveFailureClassification() {
        let delete = AnalysisProviderKeyStoreError.keychain(operation: .delete, status: errSecNotAvailable)
        #expect(delete.savedLocallyLeavingSyncedCopy(syncs: false))
        #expect(!delete.savedLocallyLeavingSyncedCopy(syncs: true))
        for error in [
            AnalysisProviderKeyStoreError.keychain(operation: .add, status: errSecNotAvailable),
            .keychain(operation: .update, status: errSecNotAvailable),
            .keychain(operation: .read, status: errSecNotAvailable),
            .notSaved,
            .unreadable,
        ] {
            #expect(!error.savedLocallyLeavingSyncedCopy(syncs: false))
            #expect(!error.savedLocallyLeavingSyncedCopy(syncs: true))
        }
    }

    @Test("Another device's synced copy beside the local key is offered alike")
    func anotherDevicesSyncedCopyIsOffered() async throws {
        let storage = InMemoryAnalysisProviderKeyStorage()
        storage.place(Data(google.utf8), provider: .google, synchronizable: false)
        storage.place(Data(replacement.utf8), provider: .google, synchronizable: true)
        let store = AnalysisProviderKeyStore(storage: storage)

        await store.refreshPresences()

        #expect(store.syncedCopyStatus(.google) == .present)
        #expect(store.syncedCopyBesideLocalKey(for: .google))
    }

    @Test("A full Remove whose readback fails, with a synced key arriving before the local delete, publishes no absence")
    func fullRemoveWithFailedReadbackPublishesNoAbsence() async throws {
        let faults = AnalysisKeychainFaultScript()
        let storage = InMemoryAnalysisProviderKeyStorage(
            seeded: [.google: (AnalysisKeyFixtures.key(google), syncs: false)],
            fault: faults.fault
        )
        let store = AnalysisProviderKeyStore(storage: storage)
        await store.refreshPresences()
        // Another device's synced key lands between the synced delete and the
        // local one, and every read after the local delete fails.
        let replacement = replacement
        faults.beforeCall { operation, synchronizable in
            if operation == .delete, !synchronizable {
                storage.place(Data(replacement.utf8), provider: .google, synchronizable: true)
                faults.fail(.read, with: errSecInteractionNotAllowed)
            }
        }

        try store.remove(provider: .google, includingSyncedCopy: true)

        #expect(forms(storage) == Forms(local: nil, synced: replacement))
        #expect(store.presence(for: .google) != AnalysisKeyPresence.none)
        #expect(store.syncedCopyStatus(.google) != .absent)
        #expect(store.lastReadFailed(.google))
    }

    @Test("A save whose readback fails shows the status as unavailable")
    func saveWithFailedReadbackIsUnavailable() throws {
        let faults = AnalysisKeychainFaultScript()
        let store = AnalysisProviderKeyStore(storage: InMemoryAnalysisProviderKeyStorage(fault: faults.fault))
        faults.beforeCall { operation, _ in
            if operation == .add {
                faults.fail(.read, with: errSecInteractionNotAllowed)
            }
        }

        try store.save(AnalysisKeyFixtures.key(google), provider: .google, syncs: true)

        #expect(store.lastReadFailed(.google))
        #expect(store.syncedCopyStatus(.google) == .unknown)
        #expect(store.removalIncludesSyncedCopy(.google))
    }

    @Test("A synced key that arrives between the synced-copy read and the presence read keeps Remove's synced scope")
    func contradictoryReadsKeepTheSyncedScope() async throws {
        let faults = AnalysisKeychainFaultScript()
        let storage = InMemoryAnalysisProviderKeyStorage(fault: faults.fault)
        let store = AnalysisProviderKeyStore(storage: storage)
        let replacement = replacement
        // The synced-copy read finds nothing; the synced key lands before the
        // presence read's local lookup.
        faults.beforeCall { operation, synchronizable in
            if operation == .read, !synchronizable {
                storage.place(Data(replacement.utf8), provider: .google, synchronizable: true)
            }
        }

        await store.refreshPresences()

        #expect(store.presence(for: .google) == .saved(synced: true))
        #expect(store.syncedCopyStatus(.google) == .present)
        #expect(store.removalScope(for: .google) == .present)
        #expect(store.removalIncludesSyncedCopy(.google))
    }

    @Test("A synced copy left beside the local key is offered for removal after a relaunch")
    func syncedCopyBesideTheLocalKeySurvivesRelaunch() async throws {
        let faults = AnalysisKeychainFaultScript()
        let storage = InMemoryAnalysisProviderKeyStorage(
            seeded: [.google: (AnalysisKeyFixtures.key(google), syncs: true)],
            fault: faults.fault
        )
        faults.fail(.delete, synchronizable: true, with: errSecNotAvailable, times: 1)
        #expect(throws: AnalysisProviderKeyStoreError.keychain(operation: .delete, status: errSecNotAvailable)) {
            try AnalysisProviderKeyStore(storage: storage).setSyncs(false, provider: .google)
        }

        let relaunched = AnalysisProviderKeyStore(storage: storage)
        await relaunched.refreshPresences()

        #expect(forms(storage) == Forms(local: google, synced: google))
        #expect(relaunched.syncedCopyBesideLocalKey(for: .google))
    }

    @Test("A failed mutation leaves the presence to the next read, which shows what was stored")
    func storeFailedMutationReadsTheTruth() async throws {
        let service = AnalysisKeychainTestService()
        defer { service.deleteAll() }
        let faults = AnalysisKeychainFaultScript()
        let store = AnalysisProviderKeyStore(storage: service.storage(fault: faults.fault))
        try store.save(AnalysisKeyFixtures.key(google), provider: .google, syncs: true)

        faults.fail(.delete, synchronizable: true, with: errSecInteractionNotAllowed)
        #expect(throws: AnalysisProviderKeyStoreError.keychain(operation: .delete, status: errSecInteractionNotAllowed)) {
            try store.setSyncs(false, provider: .google)
        }
        await store.refreshPresences()

        // The new local item was written and wins on read; the synced copy
        // it could not delete is still reported, and offered.
        #expect(store.presence(for: .google) == .saved(synced: false))
        #expect(store.syncedCopyStatus(.google) == .present)
        #expect(store.syncedCopyBesideLocalKey(for: .google))
    }

    @Test("Remove publishes what is stored after it: a synced copy another device keeps shows once the local key is gone")
    func storeRemoveShowsTheSyncedCopyThatRemains() async throws {
        let bench = Bench(.keychain)
        defer { bench.cleanUp() }
        bench.stage(.both)
        let store = AnalysisProviderKeyStore(storage: bench.storage)
        await store.refreshPresences()
        #expect(store.presence(for: .google) == .saved(synced: false))
        #expect(store.syncedCopyStatus(.google) == .present)

        try store.remove(provider: .google, includingSyncedCopy: false)

        #expect(store.presence(for: .google) == .saved(synced: true))
        #expect(try AnalysisKeyFixtures.bytes(of: store.key(for: .google)) == Data(Self.b.utf8))
    }
}
