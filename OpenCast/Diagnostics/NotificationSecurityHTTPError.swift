import Foundation

nonisolated struct NotificationSecurityHTTPError: Error, LocalizedError, Sendable {
    let statusCode: Int
    let code: String

    var errorDescription: String? {
        "Worker returned \(statusCode): \(code)"
    }

    var isRecoverableCredentialFailure: Bool {
        AppAttestRecoverableCredentialFailure.contains(statusCode: statusCode, code: code)
    }
}
