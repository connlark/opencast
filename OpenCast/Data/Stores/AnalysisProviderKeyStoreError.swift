/// Carries the Keychain operation and status only, never key material or provider text.
nonisolated enum AnalysisProviderKeyStoreError: Error, Equatable, Sendable {
    case notSaved
    /// The stored bytes are not a key.
    case unreadable
    case keychain(operation: Operation, status: Int32)

    nonisolated enum Operation: String, Sendable {
        case read
        case add
        case update
        case delete
    }

    /// A sync-off save fails at a delete only after its write, so a delete failure means this
    /// device's key is saved and only the synced copy's delete failed.
    func savedLocallyLeavingSyncedCopy(syncs: Bool) -> Bool {
        guard !syncs, case .keychain(operation: .delete, _) = self else {
            return false
        }
        return true
    }

    /// A sync-on save fails at a delete only after its write, so the synced key is saved and the
    /// local copy outlived it. That copy wins every read: read what is in use, never assume it.
    func savedSyncedLeavingLocalCopy(syncs: Bool) -> Bool {
        guard syncs, case .keychain(operation: .delete, _) = self else {
            return false
        }
        return true
    }
}
