import Foundation

nonisolated struct AppAttestErrorResponse: Decodable, Sendable {
    let error: String
    let detail: String?
}
