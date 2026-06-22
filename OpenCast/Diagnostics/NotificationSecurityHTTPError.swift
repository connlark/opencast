import Foundation

struct NotificationSecurityHTTPError: Error, LocalizedError {
    let statusCode: Int
    let code: String

    var errorDescription: String? {
        "Worker returned \(statusCode): \(code)"
    }

    var isRecoverableCredentialFailure: Bool {
        statusCode == 401
            && ["unknown_key", "invalid_app_id", "invalid_environment", "invalid_signature", "invalid_counter"].contains(code)
    }
}
