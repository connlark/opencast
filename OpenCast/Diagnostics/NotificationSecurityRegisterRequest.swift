import Foundation

struct NotificationSecurityRegisterRequest: Encodable {
    let installID: String
    let keyID: String
    let challengeID: String
    let challenge: String
    let attestationObject: String

    enum CodingKeys: String, CodingKey {
        case installID = "install_id"
        case keyID = "key_id"
        case challengeID = "challenge_id"
        case challenge
        case attestationObject = "attestation_object"
    }
}
