import CryptoKit
import Foundation

struct NotificationDeviceTokenStore {
    private static let latestTokenKey = "notifications.latestAPNsDeviceToken"
    private static let latestTokenHashKey = "notifications.latestAPNsDeviceTokenHash"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Keep only an unregister identifier; APNs supplies the token on every registration.
        if let oldToken = defaults.string(forKey: Self.latestTokenKey) {
            defaults.set(Self.hash(oldToken), forKey: Self.latestTokenHashKey)
            defaults.removeObject(forKey: Self.latestTokenKey)
        }
    }

    // Recorded only after the backend accepts the token, so the hash always names the
    // endpoint the backend holds: unregister targets it, and a differing APNs token needs an upload.
    func markUploaded(_ token: String) {
        defaults.set(Self.hash(token), forKey: Self.latestTokenHashKey)
    }

    func isUploaded(_ token: String) -> Bool {
        loadUploadedTokenHash() == Self.hash(token)
    }

    func loadUploadedTokenHash() -> String? {
        defaults.string(forKey: Self.latestTokenHashKey)
    }

    func clearLatestToken() {
        defaults.removeObject(forKey: Self.latestTokenKey)
        defaults.removeObject(forKey: Self.latestTokenHashKey)
    }

    private static func hash(_ token: String) -> String {
        hexString(for: Data(SHA256.hash(data: Data(token.utf8))))
    }

    nonisolated static func hexString(for data: Data) -> String {
        data
            .map { byte in
                let hex = String(byte, radix: 16)
                return hex.count == 1 ? "0\(hex)" : hex
            }
            .joined()
    }
}
