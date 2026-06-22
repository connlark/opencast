import Foundation

nonisolated struct NotificationDeviceUnregistrationPayload: Encodable, Sendable {
    let deviceToken: String?
    let deviceTokenHash: String?

    init(deviceToken: String? = nil, deviceTokenHash: String? = nil) {
        self.deviceToken = deviceToken
        self.deviceTokenHash = deviceTokenHash
    }

    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
        case deviceTokenHash = "device_token_hash"
    }
}
