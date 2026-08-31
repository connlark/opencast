import Foundation

struct EpisodeAdAnalysisHTTPError: LocalizedError, Sendable, Equatable {
    /// Worker cap-rejection codes (`Server/AdAnalysisWorker`): all three defer
    /// the queue identically. Classification is status + code —
    /// never the user-facing message string.
    static let capExceededCodes: Set<String> = [
        "daily_request_cap_exceeded",
        "daily_input_token_cap_exceeded",
        "global_capacity_exhausted"
    ]
    static let transientJobFailureCodes: Set<String> = [
        "job_failed_transient",
        "job_not_found"
    ]

    var statusCode: Int
    var code: String
    var detail: String?

    var isCapExceeded: Bool {
        statusCode == 429 && Self.capExceededCodes.contains(code)
    }

    var isTransientJobFailure: Bool {
        Self.transientJobFailureCodes.contains(code)
    }

    var errorDescription: String? {
        switch code {
        case "global_capacity_exhausted":
            return "Promo/ad analysis is at capacity today. Try again tomorrow."
        case "daily_request_cap_exceeded", "daily_input_token_cap_exceeded":
            return "Promo/ad analysis has reached today’s device limit. Try again tomorrow."
        default:
            break
        }

        if let detail, !detail.isEmpty {
            return "Promo/ad analysis failed (\(code)): \(detail)"
        }
        return "Promo/ad analysis failed (\(code))."
    }
}
