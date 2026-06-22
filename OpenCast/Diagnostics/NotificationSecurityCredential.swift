import Foundation

nonisolated struct NotificationSecurityCredential: Sendable {
    let installID: String
    let keyID: String
    let secureMessage: String
    let detail: String
}
