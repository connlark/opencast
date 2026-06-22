import Foundation
import Security

struct NotificationSecurityKeychain {
    private static let installIDAccount = "install-id"
    private static let appAttestKeyIDAccount = "app-attest-key-id"

    private let service: String

    init(configuration: NotificationBackendConfiguration = .current) {
        self.service = configuration.keychainService
    }

    func loadOrCreateInstallID() throws -> String {
        if let installID = try loadString(account: Self.installIDAccount) {
            return installID
        }

        let installID = UUID().uuidString
        try saveString(installID, account: Self.installIDAccount)
        return installID
    }

    func loadInstallID() throws -> String? {
        try loadString(account: Self.installIDAccount)
    }

    func loadAppAttestKeyID() throws -> String? {
        try loadString(account: Self.appAttestKeyIDAccount)
    }

    func saveAppAttestKeyID(_ keyID: String) throws {
        try saveString(keyID, account: Self.appAttestKeyIDAccount)
    }

    func deleteAppAttestKeyID() throws {
        try deleteString(account: Self.appAttestKeyIDAccount)
    }

    func deleteAll() throws {
        try deleteString(account: Self.appAttestKeyIDAccount)
        try deleteString(account: Self.installIDAccount)
    }

    private func loadString(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw NotificationSecurityKeychainError(status: status)
        }

        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            throw NotificationSecurityKeychainError(status: errSecDecode)
        }

        return value
    }

    private func saveString(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        var query = baseQuery(account: account)
        let attributes = [kSecValueData: data] as CFDictionary
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes)

        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw NotificationSecurityKeychainError(status: updateStatus)
        }

        query[kSecValueData] = data
        query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NotificationSecurityKeychainError(status: addStatus)
        }
    }

    private func deleteString(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NotificationSecurityKeychainError(status: status)
        }
    }

    private func baseQuery(account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
    }
}
