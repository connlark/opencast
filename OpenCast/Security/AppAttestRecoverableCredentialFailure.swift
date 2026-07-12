import Foundation

nonisolated enum AppAttestRecoverableCredentialFailure {
    private static let codes: Set<String> = [
        "unknown_key",
        "invalid_app_id",
        "invalid_environment",
        "invalid_signature",
        "invalid_counter"
    ]

    static func contains(statusCode: Int, code: String) -> Bool {
        statusCode == 401 && codes.contains(code)
    }
}
