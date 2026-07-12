import Foundation

nonisolated struct NotificationSecurityChallengeResponse: Decodable, Sendable {
    let challengeID: String
    let challenge: String

    enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case challenge
    }
}
