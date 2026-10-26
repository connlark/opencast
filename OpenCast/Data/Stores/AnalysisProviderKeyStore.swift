import Foundation
import Observation
import OpenCastAnalysis
import OpenCastAnalysisProviders

/// The listener's provider keys as the app sees them: whether each provider
/// has one saved, and the calls that change them. Holds no key: `key(for:)`
/// reads the storage at request time. Never logs.
///
/// Everything it publishes was read: every mutation, finished or failed, is
/// followed by a read of what is stored, and a read that fails leaves the
/// last value read in place and says so. Nothing is inferred from what a
/// mutation meant to do.
@Observable
final class AnalysisProviderKeyStore {
    @ObservationIgnored let storage: any AnalysisProviderKeyStoring
    /// Every provider, `.none` until the first read.
    private(set) var presences: [AnalysisProvider: AnalysisKeyPresence]
    /// Every provider, `unknown` until a read says, and after a read fails.
    private(set) var syncedCopyStatuses: [AnalysisProvider: AnalysisSyncedCopyStatus]
    /// Providers whose last presence read failed: their presence is the last
    /// one read, and the screen says the status is unavailable.
    private(set) var unreadProviders: Set<AnalysisProvider> = []

    /// Bumped by every mutation, so a refresh whose read started before one
    /// never publishes over the mutation's own readback.
    @ObservationIgnored private var mutationCounts: [AnalysisProvider: Int] = [:]

    /// Does not touch the storage.
    init(storage: any AnalysisProviderKeyStoring) {
        self.storage = storage
        presences = Dictionary(uniqueKeysWithValues: AnalysisProvider.allCases.map { ($0, AnalysisKeyPresence.none) })
        syncedCopyStatuses = Dictionary(uniqueKeysWithValues: AnalysisProvider.allCases.map { ($0, .unknown) })
    }

    func presence(for provider: AnalysisProvider) -> AnalysisKeyPresence {
        presences[provider] ?? AnalysisKeyPresence.none
    }

    var hasSavedKey: Bool {
        presences.values.contains { $0.isSaved }
    }

    func syncedCopyStatus(_ provider: AnalysisProvider) -> AnalysisSyncedCopyStatus {
        syncedCopyStatuses[provider] ?? .unknown
    }

    func lastReadFailed(_ provider: AnalysisProvider) -> Bool {
        unreadProviders.contains(provider)
    }

    /// What Remove deletes besides this device's key, and what its dialog
    /// says: `absent` (this device only) only when no synced copy is known
    /// or shown; `present` when one was read or the shown key is synced;
    /// otherwise `unknown`, which deletes any synced copy too.
    func removalScope(for provider: AnalysisProvider) -> AnalysisSyncedCopyStatus {
        if presence(for: provider) == .saved(synced: true) {
            return .present
        }
        return syncedCopyStatus(provider)
    }

    func removalIncludesSyncedCopy(_ provider: AnalysisProvider) -> Bool {
        removalScope(for: provider) != .absent
    }

    /// This device uses its local key and a synced copy is also stored: one
    /// a sync-off could not delete, or another device's, alike. Read from
    /// the Keychain, so it holds across launches; `removeSyncedCopy` deletes
    /// it.
    func syncedCopyBesideLocalKey(for provider: AnalysisProvider) -> Bool {
        presence(for: provider) == .saved(synced: false) && syncedCopyStatus(provider) == .present
    }

    func save(_ key: AnalysisProviderKey, provider: AnalysisProvider, syncs: Bool) throws(AnalysisProviderKeyStoreError) {
        noteMutation(of: provider)
        defer { readBack(provider) }
        try storage.save(key, provider: provider, syncs: syncs)
    }

    func key(for provider: AnalysisProvider) throws(AnalysisProviderKeyStoreError) -> AnalysisProviderKey? {
        try storage.key(for: provider)
    }

    func remove(provider: AnalysisProvider, includingSyncedCopy: Bool) throws(AnalysisProviderKeyStoreError) {
        noteMutation(of: provider)
        defer { readBack(provider) }
        try storage.remove(provider: provider, includingSyncedCopy: includingSyncedCopy)
    }

    func setSyncs(_ syncs: Bool, provider: AnalysisProvider) throws(AnalysisProviderKeyStoreError) {
        noteMutation(of: provider)
        defer { readBack(provider) }
        try storage.setSyncs(syncs, provider: provider)
    }

    /// Deletes the synced copy on every device, keeping this device's local
    /// key (`notSaved` when there is none, deleting nothing).
    func removeSyncedCopy(provider: AnalysisProvider) throws(AnalysisProviderKeyStoreError) {
        noteMutation(of: provider)
        defer { readBack(provider) }
        try storage.removeSyncedCopy(provider: provider)
    }

    /// At launch, on foreground and when AI Services opens: a key can arrive
    /// or leave through iCloud Keychain at any time. The reads run off the
    /// main actor.
    func refreshPresences() async {
        let countsBeforeRead = mutationCounts
        let readings = await Self.readStates(from: storage)
        for (provider, reading) in readings where mutationCounts[provider] == countsBeforeRead[provider] {
            publish(reading, for: provider)
        }
    }

    /// One provider's reads: `nil` presence when its read failed, `unknown`
    /// synced copy when that read failed.
    private struct Reading: Sendable {
        var presence: AnalysisKeyPresence?
        var syncedCopy: AnalysisSyncedCopyStatus
    }

    @concurrent
    private static func readStates(from storage: any AnalysisProviderKeyStoring) async -> [AnalysisProvider: Reading] {
        var readings: [AnalysisProvider: Reading] = [:]
        for provider in AnalysisProvider.allCases {
            readings[provider] = read(provider, from: storage)
        }
        return readings
    }

    private nonisolated static func read(_ provider: AnalysisProvider, from storage: any AnalysisProviderKeyStoring) -> Reading {
        let syncedCopy: AnalysisSyncedCopyStatus
        if let exists = try? storage.syncedCopyExists(for: provider) {
            syncedCopy = exists ? .present : .absent
        } else {
            syncedCopy = .unknown
        }
        return Reading(presence: try? storage.presence(for: provider), syncedCopy: syncedCopy)
    }

    /// Publishes what was read. The two reads are separate calls, so a synced
    /// key can land between them: a presence read as synced proves a synced
    /// copy, whatever the earlier read found.
    private func publish(_ reading: Reading, for provider: AnalysisProvider) {
        if let presence = reading.presence {
            presences[provider] = presence
            unreadProviders.remove(provider)
        } else {
            unreadProviders.insert(provider)
        }
        syncedCopyStatuses[provider] = reading.presence == .saved(synced: true) ? .present : reading.syncedCopy
    }

    /// After every mutation, finished or failed: a failed mutation can still
    /// have changed what is stored (a write done, its delete not).
    private func readBack(_ provider: AnalysisProvider) {
        publish(Self.read(provider, from: storage), for: provider)
    }

    private func noteMutation(of provider: AnalysisProvider) {
        mutationCounts[provider, default: 0] += 1
    }
}

extension AnalysisProviderKeyStore: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    nonisolated var description: String { "AnalysisProviderKeyStore(<redacted>)" }
    nonisolated var debugDescription: String { description }
    nonisolated var customMirror: Mirror { Mirror(self, children: []) }
}
