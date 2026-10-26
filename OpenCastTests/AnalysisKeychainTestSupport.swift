import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import Security
import Synchronization
@testable import OpenCast

/// The provider-key fixtures the UI tests type, assembled from parts so no
/// source holds a key-shaped literal.
nonisolated enum AnalysisKeyFixtures {
    static let googleText = ["AIza", "FixtureKeyForUITestsOnly", "00000000000"].joined()
    static let openAIText = ["sk-", "fixture-", "uitests-only-0123456789"].joined()
    static let replacementText = ["AIza", "ReplacementFixtureForTests", "999999999"].joined()

    static func key(_ text: String) -> AnalysisProviderKey {
        guard let key = AnalysisProviderKey(text) else {
            fatalError("A fixture key is empty")
        }
        return key
    }

    static func bytes(of key: AnalysisProviderKey?) -> Data? {
        key?.withData { $0 }
    }

    /// Whether `text` holds any 8-character run of either fixture key.
    static func containsFragment(_ text: String) -> Bool {
        [googleText, openAIText, replacementText].contains { key in
            let characters = Array(key)
            return (0...(characters.count - 8)).contains { start in
                text.contains(String(characters[start..<(start + 8)]))
            }
        }
    }
}

/// A Keychain service of its own for one test, read and written behind the
/// storage's back to stage both forms, other devices' writes and
/// interrupted mutations.
nonisolated struct AnalysisKeychainTestService {
    nonisolated struct Item: Equatable {
        var synchronizable: Bool
        var accessible: String?
        var data: Data?
    }

    let name = "opencast-analysis-key-tests-\(UUID().uuidString)"

    func storage(fault: KeychainAnalysisProviderKeyStorage.Fault? = nil) -> KeychainAnalysisProviderKeyStorage {
        KeychainAnalysisProviderKeyStorage(service: name, fault: fault)
    }

    func add(account: String, text: String, synchronizable: Bool) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: name,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: synchronizable,
            kSecAttrAccessible: synchronizable
                ? kSecAttrAccessibleAfterFirstUnlock
                : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: Data(text.utf8),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        precondition(status == errSecSuccess, "Staging a Keychain item failed with \(status)")
    }

    func replace(account: String, text: String, synchronizable: Bool) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: name,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: synchronizable,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: Data(text.utf8)] as CFDictionary)
        precondition(status == errSecSuccess, "Replacing a Keychain item failed with \(status)")
    }

    func delete(account: String, synchronizable: Bool) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: name,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: synchronizable,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Every item for `account`, synced first.
    func items(account: String) -> [Item] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: name,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnAttributes: true,
            kSecReturnData: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let rows = result as? [[String: Any]]
        else {
            return []
        }
        return rows.map { row in
            Item(
                synchronizable: (row[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue ?? false,
                accessible: row[kSecAttrAccessible as String] as? String,
                data: row[kSecValueData as String] as? Data
            )
        }
        .sorted { $0.synchronizable && !$1.synchronizable }
    }

    func deleteAll() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: name,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Scripted Security failures for the storage's fault seam: each rule fails
/// one operation on one form (or either), a number of times or for good.
/// `beforeCall` runs before every Security call, to stand in for another
/// device or process writing at that moment.
nonisolated final class AnalysisKeychainFaultScript: Sendable {
    private struct Rule {
        var operation: AnalysisProviderKeyStoreError.Operation
        var synchronizable: Bool?
        var status: OSStatus
        var remaining: Int?
    }

    private let rules = Mutex<[Rule]>([])
    private let hook = Mutex<(@Sendable (AnalysisProviderKeyStoreError.Operation, Bool) -> Void)?>(nil)

    func fail(
        _ operation: AnalysisProviderKeyStoreError.Operation,
        synchronizable: Bool? = nil,
        with status: OSStatus,
        times: Int? = nil
    ) {
        rules.withLock {
            $0.append(Rule(operation: operation, synchronizable: synchronizable, status: status, remaining: times))
        }
    }

    func beforeCall(_ action: @escaping @Sendable (AnalysisProviderKeyStoreError.Operation, Bool) -> Void) {
        hook.withLock { $0 = action }
    }

    func clear() {
        rules.withLock { $0.removeAll() }
        hook.withLock { $0 = nil }
    }

    var fault: KeychainAnalysisProviderKeyStorage.Fault {
        { [self] operation, synchronizable in
            hook.withLock { $0 }?(operation, synchronizable)
            return status(for: operation, synchronizable: synchronizable)
        }
    }

    private func status(for operation: AnalysisProviderKeyStoreError.Operation, synchronizable: Bool) -> OSStatus? {
        rules.withLock { rules in
            guard let index = rules.firstIndex(where: {
                $0.operation == operation && ($0.synchronizable ?? synchronizable) == synchronizable && $0.remaining != 0
            }) else {
                return nil
            }
            if let remaining = rules[index].remaining {
                rules[index].remaining = remaining - 1
            }
            return rules[index].status
        }
    }
}
