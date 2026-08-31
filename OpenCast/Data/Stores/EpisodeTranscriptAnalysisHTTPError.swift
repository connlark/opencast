import Foundation

struct EpisodeTranscriptAnalysisHTTPError: LocalizedError, Sendable, Equatable {
    /// Worker cap-rejection codes (`Server/TranscriptAnalysisWorker`): all
    /// three defer identically — the client queues and retries later, never
    /// surfaces a failure (caps are an abuse ceiling, not the access model).
    /// Classification is status + code — never the user-facing message string.
    static let capExceededCodes: Set<String> = [
        "daily_request_cap_exceeded",
        "daily_input_token_cap_exceeded",
        "global_capacity_exhausted"
    ]
    static let transientJobFailureCodes: Set<String> = [
        "job_failed_transient",
        "job_not_found"
    ]
    static let insufficientSecondsCode = "insufficient_transcription_seconds"
    static let bootstrapRequiredCode = "bootstrap_required"

    var statusCode: Int
    var code: String
    var detail: String?

    var isCapExceeded: Bool {
        statusCode == 429 && Self.capExceededCodes.contains(code)
    }

    var isTransientJobFailure: Bool {
        Self.transientJobFailureCodes.contains(code)
    }

    /// Typed 402: the account cannot cover the run's charge (pay gate).
    /// Deferred like a cap denial and additionally retried when the shared
    /// balance increases (H8).
    var isInsufficientSeconds: Bool {
        statusCode == 402 && code == Self.insufficientSecondsCode
    }

    /// Typed 403: the worker doesn't know this install→account link yet (or
    /// it went stale) — a bootstrap-and-retry repairs it transparently.
    var isBootstrapRequired: Bool {
        statusCode == 403 && code == Self.bootstrapRequiredCode
    }

    var errorDescription: String? {
        switch code {
        case "global_capacity_exhausted":
            return "Chapters & Summary is at capacity today. It will retry tomorrow."
        case "daily_request_cap_exceeded", "daily_input_token_cap_exceeded":
            return "Chapters & Summary has reached today’s device limit. It will retry tomorrow."
        case Self.insufficientSecondsCode:
            return "Chapters & Summary needs more transcription time."
        default:
            break
        }

        if let detail, !detail.isEmpty {
            return "Chapters & Summary failed (\(code)): \(detail)"
        }
        return "Chapters & Summary failed (\(code))."
    }
}
