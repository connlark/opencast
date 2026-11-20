import OpenCastAnalysis
import OpenCastAnalysisProviders

/// Implementations never log, and no textual or reflected form of one shows a key.
nonisolated protocol AnalysisProviderKeyStoring: Sendable {
    func save(_ key: AnalysisProviderKey, provider: AnalysisProvider, syncs: Bool) throws(AnalysisProviderKeyStoreError)
    /// Read at request time; never cached by the caller beyond the call.
    func key(for provider: AnalysisProvider) throws(AnalysisProviderKeyStoreError) -> AnalysisProviderKey?
    func remove(provider: AnalysisProvider, includingSyncedCopy: Bool) throws(AnalysisProviderKeyStoreError)
    func setSyncs(_ syncs: Bool, provider: AnalysisProvider) throws(AnalysisProviderKeyStoreError)
    /// Only while this device keeps a local key (`notSaved` otherwise), so the device is never left
    /// without one.
    func removeSyncedCopy(provider: AnalysisProvider) throws(AnalysisProviderKeyStoreError)
    /// The key a read would return: local when it exists, else synced.
    func presence(for provider: AnalysisProvider) throws(AnalysisProviderKeyStoreError) -> AnalysisKeyPresence
    func syncedCopyExists(for provider: AnalysisProvider) throws(AnalysisProviderKeyStoreError) -> Bool
}
