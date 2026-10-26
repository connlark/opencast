import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import Security
import Synchronization

/// Provider keys held in memory, for UI tests and previews: the Keychain
/// storage's two forms, read rule and call order over a dictionary, with the
/// same fault seam, so a failure can land between a mutation's write and its
/// delete and leave both forms, as the Keychain can.
nonisolated final class InMemoryAnalysisProviderKeyStorage: AnalysisProviderKeyStoring {
    typealias Fault = KeychainAnalysisProviderKeyStorage.Fault

    private nonisolated struct Forms: Sendable {
        var local: Data?
        var synced: Data?

        subscript(synchronizable: Bool) -> Data? {
            get { synchronizable ? synced : local }
            set {
                if synchronizable {
                    synced = newValue
                } else {
                    local = newValue
                }
            }
        }
    }

    private enum Form {
        case local
        case synced
    }

    /// The stored items; `place` changes them without taking `operations`,
    /// as another device or process writes the Keychain.
    private let items: Mutex<[AnalysisProvider: Forms]>
    /// One operation at a time, as the Keychain storage's lock.
    private let operations = Mutex(())
    private let fault: Fault?

    init(seeded: [AnalysisProvider: (AnalysisProviderKey, syncs: Bool)] = [:], fault: Fault? = nil) {
        var items: [AnalysisProvider: Forms] = [:]
        for (provider, entry) in seeded {
            entry.0.withData { data in
                items[provider, default: Forms()][entry.syncs] = data
            }
        }
        self.items = Mutex(items)
        self.fault = fault
    }

    /// Writes (or with `nil` deletes) one form behind the storage's back, as
    /// another device or process would.
    func place(_ data: Data?, provider: AnalysisProvider, synchronizable: Bool) {
        items.withLock { $0[provider, default: Forms()][synchronizable] = data }
    }

    /// Both forms as stored, read behind the storage's back (tests).
    func stored(_ provider: AnalysisProvider) -> (local: Data?, synced: Data?) {
        items.withLock { ($0[provider]?.local, $0[provider]?.synced) }
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

    // MARK: - The Keychain storage's calls, over the dictionary

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
        var data: Data?
        let status = perform(.read, synchronizable: synchronizable) {
            data = items.withLock { $0[provider]?[synchronizable] }
            return data == nil ? errSecItemNotFound : errSecSuccess
        }
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw .keychain(operation: .read, status: status)
        }
        guard let data else {
            throw .unreadable
        }
        return data
    }

    private func write(_ data: Data, provider: AnalysisProvider, synchronizable: Bool) throws(AnalysisProviderKeyStoreError) {
        let add = {
            self.items.withLock { items -> OSStatus in
                guard items[provider]?[synchronizable] == nil else {
                    return errSecDuplicateItem
                }
                items[provider, default: Forms()][synchronizable] = data
                return errSecSuccess
            }
        }
        let addStatus = perform(.add, synchronizable: synchronizable, add)
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw .keychain(operation: .add, status: addStatus)
        }
        let updateStatus = perform(.update, synchronizable: synchronizable) {
            self.items.withLock { items -> OSStatus in
                guard items[provider]?[synchronizable] != nil else {
                    return errSecItemNotFound
                }
                items[provider, default: Forms()][synchronizable] = data
                return errSecSuccess
            }
        }
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw .keychain(operation: .update, status: updateStatus)
        }
        let retryStatus = perform(.add, synchronizable: synchronizable, add)
        guard retryStatus == errSecSuccess else {
            throw .keychain(operation: .add, status: retryStatus)
        }
    }

    private func delete(provider: AnalysisProvider, synchronizable: Bool) throws(AnalysisProviderKeyStoreError) {
        let status = perform(.delete, synchronizable: synchronizable) {
            items.withLock { items -> OSStatus in
                guard items[provider]?[synchronizable] != nil else {
                    return errSecItemNotFound
                }
                items[provider]?[synchronizable] = nil
                return errSecSuccess
            }
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw .keychain(operation: .delete, status: status)
        }
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
        let outcome: Swift.Result<Result, AnalysisProviderKeyStoreError> = operations.withLock { _ in
            do throws(AnalysisProviderKeyStoreError) {
                return .success(try body())
            } catch {
                return .failure(error)
            }
        }
        return try outcome.get()
    }
}

nonisolated extension InMemoryAnalysisProviderKeyStorage: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "InMemoryAnalysisProviderKeyStorage(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: []) }
}
