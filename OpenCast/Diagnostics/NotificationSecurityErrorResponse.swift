import Foundation

nonisolated struct NotificationSecurityErrorResponse: Decodable, Sendable {
    let error: String
}
