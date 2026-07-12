import Foundation

nonisolated struct AppAttestHTTPError: Error, LocalizedError, Equatable, Sendable {
    let statusCode: Int
    let code: String
    let detail: String?

    var errorDescription: String? {
        if let detail, !detail.isEmpty {
            return "Server returned \(statusCode): \(code) (\(detail))"
        }
        return "Server returned \(statusCode): \(code)"
    }

    var isRecoverableCredentialFailure: Bool {
        AppAttestRecoverableCredentialFailure.contains(statusCode: statusCode, code: code)
    }
}
