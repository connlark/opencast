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

    /// A lost counter race specifically — the key is fine, only this
    /// assertion's counter arrived stale, so one fresh assertion suffices
    /// where the recoverable-credential path would delete and re-attest.
    var isCounterRaceFailure: Bool {
        statusCode == 401 && code == "invalid_counter"
    }
}
