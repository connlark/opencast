import Foundation

struct NotificationSecurityChallengeResponse: Decodable {
    let challengeID: String
    let challenge: String

    enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case challenge
    }
}
