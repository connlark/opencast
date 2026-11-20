import Foundation

/// Classify by status and code, never by the message.
struct EpisodeTranscriptAnalysisHTTPError: LocalizedError, Sendable, Equatable {
    static let jobUnavailableCode = "job_unavailable"
    static let transientServerStatusCodes: Set<Int> = [500, 502, 503, 504]

    var statusCode: Int
    var code: String
    var detail: String?

    /// `http_<status>` is the client's code for a 5xx with no JSON body; every coded worker error
    /// stays terminal.
    var isTransientPollFailure: Bool {
        code == Self.jobUnavailableCode
            || code.hasPrefix("http_") && Self.transientServerStatusCodes.contains(statusCode)
    }

    var errorDescription: String? {
        if let detail, !detail.isEmpty {
            return "Chapters & Summary failed (\(code)): \(detail)"
        }
        return "Chapters & Summary failed (\(code))."
    }
}
