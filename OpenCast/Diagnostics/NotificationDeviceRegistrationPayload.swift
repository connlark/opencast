import Foundation

nonisolated struct NotificationDeviceRegistrationPayload: Encodable, Sendable {
    let deviceToken: String
    let apnsEnvironment: String
    let appVersion: String?
    let appBuild: String?

    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
        case apnsEnvironment = "apns_environment"
        case appVersion = "app_version"
        case appBuild = "app_build"
    }
}
