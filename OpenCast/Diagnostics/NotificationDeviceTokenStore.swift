import Foundation

struct NotificationDeviceTokenStore {
    private static let latestTokenKey = "notifications.latestAPNsDeviceToken"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(_ deviceToken: Data) -> String {
        let token = Self.hexString(for: deviceToken)
        defaults.set(token, forKey: Self.latestTokenKey)
        return token
    }

    func loadLatestToken() -> String? {
        defaults.string(forKey: Self.latestTokenKey)
    }

    func clearLatestToken() {
        defaults.removeObject(forKey: Self.latestTokenKey)
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
