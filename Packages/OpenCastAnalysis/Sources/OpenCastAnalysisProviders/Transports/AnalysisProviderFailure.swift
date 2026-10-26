import OpenCastAnalysis

/// What the listener is told when a provider call fails: one case per row
/// of the provider error table, plus an unreachable provider, any other
/// refusal, the trial service's own refusals, and a key gone mid-run. The
/// run record stores the raw value. Carries no provider text.
public enum AnalysisProviderFailure: String, Sendable, Hashable, CaseIterable, Codable {
    /// The provider refused the key ("Key not accepted", with Test again).
    case invalidKey = "invalid_key"
    /// The account needs billing, quota or prepaid credit.
    case billingOrQuota = "billing_or_quota"
    /// The key's project used its provider's daily limit (Gemini's free
    /// tier counts per project and resets at midnight Pacific). Final for
    /// the run, never paced.
    case dailyLimit = "daily_limit"
    /// The key is rate limited. Paced silently; shown only when the run
    /// could not finish inside its budget.
    case rateLimited = "rate_limited"
    /// The model is unknown to the provider or not available to the key.
    case modelUnavailable = "model_unavailable"
    /// The provider answered with a server error ("Provider busy").
    case overloaded
    /// The call did not complete before its deadline.
    case timeout
    /// The answer could not be used: truncated, oversized, not UTF-8, not
    /// the provider's shape, or rejected by the validator.
    case malformedAnswer = "malformed_answer"
    /// The provider could not be reached.
    case unreachable
    /// Any other refusal of the request.
    case requestRejected = "request_rejected"
    /// The install's free trial analyses are used up.
    case trialExhausted = "trial_exhausted"
    /// The episode needs more than one trial analysis covers.
    case trialRunBound = "trial_run_bound"
    /// The trial is paused for now (its allowance for the period is spent).
    case trialPaused = "trial_paused"
    /// The trial service is unavailable.
    case trialUnavailable = "trial_unavailable"
    /// The listener's key for the run's provider was removed, replaced or
    /// could not be read before a send; nothing reached the provider and
    /// the run needs a key again.
    case keyRequired = "key_required"
}

/// One failed exchange, classified once for both audiences: the pipeline's
/// retry ladder and the listener-facing surface.
public struct AnalysisProviderErrorClassification: Error, Sendable, Hashable {
    public var transport: AnalysisTransportError
    public var listener: AnalysisProviderFailure

    public init(transport: AnalysisTransportError, listener: AnalysisProviderFailure) {
        self.transport = transport
        self.listener = listener
    }

    /// An exchange that produced no response at all.
    public init(_ failure: AnalysisHTTPFailure) {
        switch failure {
        case .timeout: self.init(transport: .timeout, listener: .timeout)
        case .network: self.init(transport: .network, listener: .unreachable)
        case .oversizedBody: self.init(transport: .oversizedBody, listener: .malformedAnswer)
        }
    }

    /// A body that was not UTF-8.
    public static let invalidEncoding = AnalysisProviderErrorClassification(
        transport: .invalidEncoding,
        listener: .malformedAnswer
    )
}

extension AnalysisProviderFailure {
    /// The listener-facing failure of a finished run, or `nil` when the run
    /// succeeded or failed for a reason that is not the provider's (a request
    /// the pipeline refused, a cancellation). Prefers what the provider said
    /// on the last failed send of the window that failed the run (any window
    /// for a whole-run failure), never a send the run cancelled; otherwise
    /// reads the run's failure code.
    public static func resolve(_ outcome: AnalysisOutcome, sends: [AnalysisProviderSendRecord]) -> AnalysisProviderFailure? {
        guard case .failed(let failure) = outcome else { return nil }
        let answered = sends.filter { !$0.cancelled }
        let scoped = failure.windowIndex.map { window in answered.filter { $0.purpose.windowIndex == window } } ?? answered
        let lastFailure = (scoped.last { $0.failure != nil } ?? answered.last { $0.failure != nil })?.failure
        let rateLimited = answered.contains { $0.failure == .rateLimited }
        switch failure.code {
        case .quotaExhausted:
            return lastFailure == .dailyLimit ? .dailyLimit : .billingOrQuota
        case .providerRejected:
            return lastFailure ?? .requestRejected
        case .retryExhausted:
            return lastFailure ?? .overloaded
        case .timeout:
            return rateLimited ? .rateLimited : .timeout
        case .network:
            return lastFailure ?? .unreachable
        case .responseOversized, .responseEncoding:
            return .malformedAnswer
        case .analysisDeadlineExhausted:
            return rateLimited ? .rateLimited : .timeout
        case .adAnalysisIncomplete, .repairFeedbackExceeded, .invalidModelOutput, .modelOutputTruncated:
            return .malformedAnswer
        case .transcriptTooLong, .unsupportedSchemaVersion, .emptyRequestID, .emptyEpisodeID,
             .emptyPodcastID, .transcriptNotCompleted, .metadataFieldTooLarge, .invalidTranscriptMetadata,
             .segmentCountMismatch, .emptySegments, .segmentCountExceeded, .duplicateSegmentID,
             .emptySegmentText, .segmentTextTooLarge, .invalidSegmentTiming, .nonMonotonicSegments,
             .transcriptTextTooLarge, .estimatedInputTooLarge, .replayMissingReply, .cancelled:
            return nil
        }
    }
}

extension AnalysisProviderRequest.Purpose {
    /// The ad-detection window a request belongs to; `nil` for Chapters.
    public var windowIndex: Int? {
        switch self {
        case .adWindow(let index), .adRepair(let index): index
        case .chapters: nil
        }
    }
}
