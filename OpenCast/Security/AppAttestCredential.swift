import Foundation

nonisolated struct AppAttestCredential: Sendable {
    let installID: String
    let keyID: String
    let secureMessage: String
    let detail: String
}
