import CryptoKit
import Foundation
import Testing
@testable import OpenCast

@MainActor
@Suite("Notification token unregister identifier")
struct NotificationDeviceTokenStoreTests {
    @Test("Legacy raw tokens are removed and retained only as unregister hashes")
    func migratesRawToken() throws {
        let name = "NotificationDeviceTokenStoreTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("010203", forKey: "notifications.latestAPNsDeviceToken")
        let store = NotificationDeviceTokenStore(defaults: defaults)
        let expectedHash = NotificationDeviceTokenStore.hexString(for: Data(SHA256.hash(data: Data("010203".utf8))))
        #expect(store.loadUploadedTokenHash() == expectedHash)
        #expect(store.isUploaded("010203"))
        #expect(defaults.string(forKey: "notifications.latestAPNsDeviceToken") == nil)
        store.clearLatestToken()
        #expect(store.loadUploadedTokenHash() == nil)
    }

    @Test("Only a token the backend accepted counts as uploaded")
    func tracksUploadedToken() throws {
        let name = "NotificationDeviceTokenStoreTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = NotificationDeviceTokenStore(defaults: defaults)
        #expect(!store.isUploaded("010203"))

        store.markUploaded("010203")
        #expect(store.isUploaded("010203"))
        #expect(!store.isUploaded("040506"))
        #expect(defaults.dictionaryRepresentation().values.allSatisfy { ($0 as? String) != "010203" })

        store.markUploaded("040506")
        #expect(!store.isUploaded("010203"))
        store.clearLatestToken()
        #expect(!store.isUploaded("040506"))
    }
}
