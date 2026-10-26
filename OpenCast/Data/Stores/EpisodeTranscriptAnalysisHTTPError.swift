import Foundation

/// A job read from the analysis service failed. Only the drain of a job the
/// service accepted before the update reads it; classification is status +
/// code, never the message string.
struct EpisodeTranscriptAnalysisHTTPError: LocalizedError, Sendable, Equatable {
    static let transientJobFailureCodes: Set<String> = [
        "job_failed_transient",
        "job_not_found"
    ]
    static let jobUnavailableCode = "job_unavailable"
    static let transientServerStatusCodes: Set<Int> = [500, 502, 503, 504]

    var statusCode: Int
    var code: String
    var detail: String?

    var isTransientJobFailure: Bool {
        Self.transientJobFailureCodes.contains(code)
    }

    /// A read of an accepted job that failed without a verdict: an
    /// unavailable job object or a 5xx with no JSON body (the client's
    /// synthesized `http_<status>` code). The poller retries the same
    /// handle; every coded worker error stays terminal.
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
