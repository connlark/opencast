import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import Security
import Synchronization

/// Provider keys as generic-password Keychain items, one credential per
/// provider in one of two forms: **synced** (`AfterFirstUnlock`,
/// synchronizable, so iCloud Keychain carries it to the listener's other
/// devices) or **local** (`AfterFirstUnlockThisDeviceOnly`, never synced,
/// not even through a backup).
///
/// `kSecAttrSynchronizable` is part of an item's primary key, so both forms
/// can exist at once: a mutation interrupted between its two calls, or a
/// synced key another device saved while this one keeps a local key. Reads
/// take the local form when it exists, else the synced one. Every mutation
/// is at most two steps in a fixed order, a write of one form before a
/// delete of the other, and every delete names only the form, never the
/// bytes.
///
/// Deleting the synced form deletes it on the listener's other devices too,
/// so only three things delete it: this device turning sync off for the key
/// it was using in that form (a switch, or a save with sync off), finishing
/// such a sync-off whose delete failed, and a Remove the listener confirmed
/// for the synced copy. A local save on a
/// device that already keeps a local key leaves another device's synced key
/// alone.
nonisolated struct KeychainAnalysisProviderKeyStorage: AnalysisProviderKeyStoring {
    static let defaultService = "com.connor.opencast.analysis-provider-keys"

    /// Test seam: called before each Security call with the operation and
    /// the form it names (`true` synced, `false` local); a returned status
    /// replaces the call, `nil` makes it.
    typealias Fault = @Sendable (AnalysisProviderKeyStoreError.Operation, _ synchronizable: Bool) -> OSStatus?

    private enum Form {
        case local
        case synced
    }

    /// One process-wide lock around every mutation and every read, so no
    /// reader in this process sees a half-applied mutation and two mutations
    /// never interleave. Other processes and iCloud Keychain are not
    /// excluded: a synced item they replace between this device's read and
    /// its delete of that form is deleted with it.
    private static let lock = Mutex(())

    private let service: String
    private let fault: Fault?

    init(service: String = KeychainAnalysisProviderKeyStorage.defaultService, fault: Fault? = nil) {
        self.service = service
        self.fault = fault
    }

    func save(_ key: AnalysisProviderKey, provider: AnalysisProvider, syncs: Bool) throws(AnalysisProviderKeyStoreError) {
        try serialized { () throws(AnalysisProviderKeyStoreError) in
            let before = try resolved(provider)?.form
            try key.withData { (data: Data) throws(AnalysisProviderKeyStoreError) in
                try write(data, provider: provider, synchronizable: syncs)
            }
            if syncs {
                try delete(provider: provider, synchronizable: false)
            } else if before == .synced {
                try delete(provider: provider, synchronizable: true)
            }
        }
    }

    func key(for provider: AnalysisProvider) throws(AnalysisProviderKeyStoreError) -> AnalysisProviderKey? {
        let item = try serialized { () throws(AnalysisProviderKeyStoreError) in
            try resolved(provider)
        }
        guard let item else {
            return nil
        }
        guard let text = String(data: item.data, encoding: .utf8), let key = AnalysisProviderKey(text) else {
            throw .unreadable
        }
        return key
    }

    func remove(provider: AnalysisProvider, includingSyncedCopy: Bool) throws(AnalysisProviderKeyStoreError) {
        try serialized { () throws(AnalysisProviderKeyStoreError) in
            // The synced copy first: if that fails, this device still holds
            // the key it showed, never another device's.
            if includingSyncedCopy {
                try delete(provider: provider, synchronizable: true)
            }
            try delete(provider: provider, synchronizable: false)
        }
    }

    func setSyncs(_ syncs: Bool, provider: AnalysisProvider) throws(AnalysisProviderKeyStoreError) {
        try serialized { () throws(AnalysisProviderKeyStoreError) in
            guard let current = try resolved(provider) else {
                throw .notSaved
            }
            guard (current.form == .synced) != syncs else {
                return
            }
            try write(current.data, provider: provider, synchronizable: syncs)
            try delete(provider: provider, synchronizable: !syncs)
        }
    }

    func removeSyncedCopy(provider: AnalysisProvider) throws(AnalysisProviderKeyStoreError) {
        try serialized { () throws(AnalysisProviderKeyStoreError) in
            guard try read(provider, synchronizable: false) != nil else {
                throw .notSaved
            }
            try delete(provider: provider, synchronizable: true)
        }
    }

    func presence(for provider: AnalysisProvider) throws(AnalysisProviderKeyStoreError) -> AnalysisKeyPresence {
        let form = try serialized { () throws(AnalysisProviderKeyStoreError) in
            try resolved(provider)?.form
        }
        switch form {
        case .local: return .saved(synced: false)
        case .synced: return .saved(synced: true)
        case nil: return AnalysisKeyPresence.none
        }
    }

    func syncedCopyExists(for provider: AnalysisProvider) throws(AnalysisProviderKeyStoreError) -> Bool {
        try serialized { () throws(AnalysisProviderKeyStoreError) in
            try read(provider, synchronizable: true) != nil
        }
    }

    // MARK: - Reads

    /// The local form when it exists, else the synced one. Only "not found"
    /// means absent: an unreadable local item throws rather than falling
    /// back to a synced key this device did not choose.
    private func resolved(_ provider: AnalysisProvider) throws(AnalysisProviderKeyStoreError) -> (form: Form, data: Data)? {
        if let local = try read(provider, synchronizable: false) {
            return (.local, local)
        }
        if let synced = try read(provider, synchronizable: true) {
            return (.synced, synced)
        }
        return nil
    }

    private func read(_ provider: AnalysisProvider, synchronizable: Bool) throws(AnalysisProviderKeyStoreError) -> Data? {
        var query = baseQuery(provider, synchronizable: synchronizable)
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true
        var result: CFTypeRef?
        let status = perform(.read, synchronizable: synchronizable) {
            SecItemCopyMatching(query as CFDictionary, &result)
        }
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw .keychain(operation: .read, status: status)
        }
        guard let data = result as? Data else {
            throw .unreadable
        }
        return data
    }

    // MARK: - Writes

    /// Adds the form; a duplicate is updated in place (data and class). An
    /// update that finds nothing (the item went away in between) adds once
    /// more and fails if that does, so the caller never deletes the other
    /// form without this one in place.
    private func write(_ data: Data, provider: AnalysisProvider, synchronizable: Bool) throws(AnalysisProviderKeyStoreError) {
        let itemQuery = baseQuery(provider, synchronizable: synchronizable)
        let accessibility = Self.accessibility(synchronizable: synchronizable)
        var addition = itemQuery
        addition[kSecValueData] = data
        addition[kSecAttrAccessible] = accessibility
        let addStatus = perform(.add, synchronizable: synchronizable) {
            SecItemAdd(addition as CFDictionary, nil)
        }
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw .keychain(operation: .add, status: addStatus)
        }
        let update: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: accessibility]
        let updateStatus = perform(.update, synchronizable: synchronizable) {
            SecItemUpdate(itemQuery as CFDictionary, update as CFDictionary)
        }
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw .keychain(operation: .update, status: updateStatus)
        }
        let retryStatus = perform(.add, synchronizable: synchronizable) {
            SecItemAdd(addition as CFDictionary, nil)
        }
        guard retryStatus == errSecSuccess else {
            throw .keychain(operation: .add, status: retryStatus)
        }
    }

    /// Names only service, account and form. Nothing to delete is success.
    private func delete(provider: AnalysisProvider, synchronizable: Bool) throws(AnalysisProviderKeyStoreError) {
        let query = baseQuery(provider, synchronizable: synchronizable)
        let status = perform(.delete, synchronizable: synchronizable) {
            SecItemDelete(query as CFDictionary)
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw .keychain(operation: .delete, status: status)
        }
    }

    /// A synced item must be readable on the listener's other devices; a
    /// local one never leaves this device.
    private static func accessibility(synchronizable: Bool) -> CFString {
        synchronizable ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }

    private func baseQuery(_ provider: AnalysisProvider, synchronizable: Bool) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: provider.rawValue,
            kSecAttrSynchronizable: synchronizable,
        ]
    }

    private func perform(
        _ operation: AnalysisProviderKeyStoreError.Operation,
        synchronizable: Bool,
        _ call: () -> OSStatus
    ) -> OSStatus {
        if let status = fault?(operation, synchronizable) {
            return status
        }
        return call()
    }

    private func serialized<Result>(
        _ body: () throws(AnalysisProviderKeyStoreError) -> Result
    ) throws(AnalysisProviderKeyStoreError) -> Result {
        let outcome: Swift.Result<Result, AnalysisProviderKeyStoreError> = Self.lock.withLock { _ in
            do throws(AnalysisProviderKeyStoreError) {
                return .success(try body())
            } catch {
                return .failure(error)
            }
        }
        return try outcome.get()
    }
}

nonisolated extension KeychainAnalysisProviderKeyStorage: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "KeychainAnalysisProviderKeyStorage(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: []) }
}
