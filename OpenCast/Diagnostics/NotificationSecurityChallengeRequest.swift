import Foundation

struct NotificationSecurityChallengeRequest: Encodable {
    let installID: String
    let purpose: String

    enum CodingKeys: String, CodingKey {
        case installID = "install_id"
        case purpose
    }
}
