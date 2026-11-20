import Foundation
import Observation
import OpenCastAnalysis
import OpenCastAnalysisProviders

/// Holds no key and never logs. Everything it publishes was read back from storage after each
/// mutation, finished or failed; nothing is inferred from what a mutation meant to do. A failed
/// read leaves the last value read in place and says so.
@Observable
final class AnalysisProviderKeyStore {
    @ObservationIgnored let storage: any AnalysisProviderKeyStoring
    private(set) var presences: [AnalysisProvider: AnalysisKeyPresence]
    private(set) var syncedCopyStatuses: [AnalysisProvider: AnalysisSyncedCopyStatus]
    private(set) var unreadProviders: Set<AnalysisProvider> = []

    /// Bumped by every mutation, so a refresh whose read started before one
    /// never publishes over the mutation's own readback.
    @ObservationIgnored private var mutationCounts: [AnalysisProvider: Int] = [:]

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

    /// `unknown` counts as present: Remove then deletes any synced copy too.
    func removalScope(for provider: AnalysisProvider) -> AnalysisSyncedCopyStatus {
        if presence(for: provider) == .saved(synced: true) {
            return .present
        }
        return syncedCopyStatus(provider)
    }

    func removalIncludesSyncedCopy(_ provider: AnalysisProvider) -> Bool {
        removalScope(for: provider) != .absent
    }

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

    func removeSyncedCopy(provider: AnalysisProvider) throws(AnalysisProviderKeyStoreError) {
        noteMutation(of: provider)
        defer { readBack(provider) }
        try storage.removeSyncedCopy(provider: provider)
    }

    func refreshPresences() async {
        let countsBeforeRead = mutationCounts
        let readings = await Self.readStates(from: storage)
        for (provider, reading) in readings where mutationCounts[provider] == countsBeforeRead[provider] {
            publish(reading, for: provider)
        }
    }

    /// A `nil` presence means its read failed.
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

    /// The two reads are separate calls, so a synced key can land between them: a presence read as
    /// synced proves a synced copy, whatever the earlier read found.
    private func publish(_ reading: Reading, for provider: AnalysisProvider) {
        if let presence = reading.presence {
            presences[provider] = presence
            unreadProviders.remove(provider)
        } else {
            unreadProviders.insert(provider)
        }
        syncedCopyStatuses[provider] = reading.presence == .saved(synced: true) ? .present : reading.syncedCopy
    }

    /// Runs after failed mutations too: one can still have changed what is stored.
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
