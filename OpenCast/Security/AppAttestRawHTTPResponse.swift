import Foundation

/// A reply to an App Attest envelope, read whole and capped but not
/// decoded: the status, the two headers its callers read, and the body.
/// The body can echo request content, so no textual or reflected form
/// shows it.
nonisolated struct AppAttestRawHTTPResponse: Sendable, Equatable {
    let statusCode: Int
    let retryAfter: String?
    let contentType: String?
    let body: Data
    /// The service's own error code, for a non-2xx body `{"error": "<code>"}`.
    let errorCode: String?

    init(statusCode: Int, retryAfter: String?, contentType: String?, body: Data) {
        self.statusCode = statusCode
        self.retryAfter = retryAfter
        self.contentType = contentType
        self.body = body
        errorCode = (200..<300).contains(statusCode)
            ? nil
            : (try? JSONDecoder().decode(AppAttestErrorResponse.self, from: body))?.error
    }

    /// A lost counter race: one fresh assertion clears it.
    var isCounterRaceFailure: Bool {
        statusCode == 401 && errorCode == "invalid_counter"
    }

    /// The rejection as the decoding clients throw it, when a new key could
    /// clear it; `nil` for every other reply.
    var recoverableCredentialFailure: AppAttestHTTPError? {
        guard let errorCode, AppAttestRecoverableCredentialFailure.contains(statusCode: statusCode, code: errorCode) else {
            return nil
        }
        return AppAttestHTTPError(statusCode: statusCode, code: errorCode, detail: nil)
    }
}

nonisolated extension AppAttestRawHTTPResponse: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "status=\(statusCode) bytes=\(body.count)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["statusCode": statusCode, "bodyBytes": body.count]) }
}
