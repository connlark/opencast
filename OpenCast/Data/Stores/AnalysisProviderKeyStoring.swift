import OpenCastAnalysis
import OpenCastAnalysisProviders

/// Where the listener's provider keys live. Implementations never log, and
/// no textual or reflected form of one shows a key.
nonisolated protocol AnalysisProviderKeyStoring: Sendable {
    func save(_ key: AnalysisProviderKey, provider: AnalysisProvider, syncs: Bool) throws(AnalysisProviderKeyStoreError)
    /// Read at request time; never cached by the caller beyond the call.
    func key(for provider: AnalysisProvider) throws(AnalysisProviderKeyStoreError) -> AnalysisProviderKey?
    /// Deletes this device's key, and the synced copy on every device only
    /// when `includingSyncedCopy` (what the listener confirmed).
    func remove(provider: AnalysisProvider, includingSyncedCopy: Bool) throws(AnalysisProviderKeyStoreError)
    func setSyncs(_ syncs: Bool, provider: AnalysisProvider) throws(AnalysisProviderKeyStoreError)
    /// Deletes the synced copy on every device, only while this device keeps
    /// a local key (`notSaved` otherwise, deleting nothing): finishes turning
    /// sync off when its delete failed, and never leaves this device without
    /// a key.
    func removeSyncedCopy(provider: AnalysisProvider) throws(AnalysisProviderKeyStoreError)
    /// The key a read would return: local when it exists, else synced.
    func presence(for provider: AnalysisProvider) throws(AnalysisProviderKeyStoreError) -> AnalysisKeyPresence
    /// Whether a synced copy exists, shown or not (a local key wins on read).
    func syncedCopyExists(for provider: AnalysisProvider) throws(AnalysisProviderKeyStoreError) -> Bool
}
