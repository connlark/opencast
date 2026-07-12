import Foundation

nonisolated struct NotificationSecurityMessageResponse: Decodable, Sendable {
    let message: String
}
