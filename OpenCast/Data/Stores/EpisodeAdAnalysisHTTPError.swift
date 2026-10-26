import Foundation
import OpenCastAnalysisProviders
import OpenCastTranscription

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
    static let jobUnavailableCode = "job_unavailable"
    static let transientServerStatusCodes: Set<Int> = [500, 502, 503, 504]

    var statusCode: Int
    var code: String
    var detail: String?
    var failure: OpenCastAdAnalysisFailure? = nil
    /// What the listener is told about a device run's failure; `nil` for
    /// the service's errors and for failures that are not the provider's.
    var listenerFailure: AnalysisProviderFailure? = nil

    var isCapExceeded: Bool {
        failure?.category == .capacity || code == "gemini_quota_exhausted"
            || statusCode == 429 && Self.capExceededCodes.contains(code)
    }

    var isTransientJobFailure: Bool {
        failure?.category == .interruptedJob || Self.transientJobFailureCodes.contains(code)
    }

    /// A read of an accepted job that failed without a verdict: the worker's
    /// untyped `job_unavailable` (its job object threw) or any untyped 5xx
    /// such as the platform's plain-text 500. The poller retries the same
    /// handle; a typed failure the job stored (`usage_limiter_error`,
    /// `gemini_*`) stays terminal.
    var isTransientPollFailure: Bool {
        guard !isCapExceeded, !isTransientJobFailure else { return false }
        return code == Self.jobUnavailableCode
            || failure == nil && Self.transientServerStatusCodes.contains(statusCode)
    }

    var replayFailure: OpenCastAdAnalysisFailure? {
        if let failure { return failure }
        if code == "ad_analysis_incomplete" || code == "repair_feedback_exceeded" {
            return .init(category: .validationExhausted, retryDisposition: .explicitRetry)
        }
        return nil
    }

    var errorDescription: String? {
        switch code {
        case "ad_analysis_incomplete", "repair_feedback_exceeded":
            return "Complete ad boundaries could not be verified. Automatic retries are paused for this transcript. You can retry Detect Ads."
        case "ambiguous_legacy_job":
            return "This older ad-analysis job needs a new polling reference. Retry Detect Ads."
        case "gemini_quota_exhausted" where listenerFailure == nil:
            // The service's shared key; a device run's quota is the
            // listener's own and keeps its listener failure.
            return "Promo/ad analysis is at capacity. Try again later."
        case "global_capacity_exhausted":
            return "Promo/ad analysis is at capacity today. Try again tomorrow."
        case "daily_request_cap_exceeded", "daily_input_token_cap_exceeded":
            return "Promo/ad analysis has reached today’s device limit. Try again tomorrow."
        default:
            break
        }

        let reason = listenerFailure.map { "\(code), \($0.rawValue)" } ?? code
        if let detail, !detail.isEmpty {
            return "Promo/ad analysis failed (\(reason)): \(detail)"
        }
        return "Promo/ad analysis failed (\(reason))."
    }
}

extension EpisodeAdAnalysisHTTPError {
    /// An error body as the ad-analysis service writes it, read the one way
    /// both the service's replies and a device run's failures are read; a
    /// body that is not one reads as `http_<status>`.
    init(statusCode: Int, body: Data, listenerFailure: AnalysisProviderFailure? = nil) {
        let errorResponse = try? EpisodeAdAnalysisJSONCoding.decoder()
            .decode(EpisodeAdAnalysisAPIErrorResponse.self, from: body)
        self.init(
            statusCode: statusCode,
            code: errorResponse?.error ?? "http_\(statusCode)",
            detail: errorResponse?.detail,
            failure: errorResponse?.failure,
            listenerFailure: listenerFailure
        )
    }
}
