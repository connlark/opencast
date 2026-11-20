import Foundation
import OpenCastTranscription

nonisolated struct AppAttestHTTPError: Error, LocalizedError, Equatable, Sendable {
    let statusCode: Int
    let code: String
    let detail: String?
    var failure: OpenCastAdAnalysisFailure? = nil

    static let responseTooLarge = AppAttestHTTPError(statusCode: -1, code: "response_too_large", detail: nil)

    var errorDescription: String? {
        if let detail, !detail.isEmpty {
            return "Server returned \(statusCode): \(code) (\(detail))"
        }
        return "Server returned \(statusCode): \(code)"
    }

    var isRecoverableCredentialFailure: Bool {
        AppAttestRecoverableCredentialFailure.contains(statusCode: statusCode, code: code)
    }

    /// The key is fine and only this assertion's counter arrived stale, so one fresh assertion
    /// suffices, with no delete and re-attest.
    var isCounterRaceFailure: Bool {
        statusCode == 401 && code == "invalid_counter"
    }
}
