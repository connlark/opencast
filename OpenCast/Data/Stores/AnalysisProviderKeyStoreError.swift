/// Why a provider key could not be read or changed. Carries the Keychain
/// operation and its status only: never key material or provider text.
nonisolated enum AnalysisProviderKeyStoreError: Error, Equatable, Sendable {
    /// `setSyncs` on a provider with no saved key.
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

    /// Whether a save or switch with sync off that threw this had already
    /// written this device's key: such a call fails at a delete only after
    /// its write, so the key is saved here and only the synced copy's delete
    /// failed. Any other failure saved nothing new.
    func savedLocallyLeavingSyncedCopy(syncs: Bool) -> Bool {
        guard !syncs, case .keychain(operation: .delete, _) = self else {
            return false
        }
        return true
    }
}
