import Foundation

nonisolated struct NotificationSecurityAuthenticatedEnvelope: Encodable, Sendable {
    let installID: String
    let keyID: String
    let payload: String
    let assertion: String?

    enum CodingKeys: String, CodingKey {
        case installID = "install_id"
        case keyID = "key_id"
        case payload
        case assertion
    }
}
