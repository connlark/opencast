import OpenCastAnalysis

/// Run records store the raw value. Carries no provider text.
public enum AnalysisProviderFailure: String, Sendable, Hashable, CaseIterable, Codable {
    case invalidKey = "invalid_key"
    case billingOrQuota = "billing_or_quota"
    /// Gemini's free tier counts per project and resets at midnight Pacific. Final for the run,
    /// never paced.
    case dailyLimit = "daily_limit"
    /// Paced silently; shown only when the run cannot finish inside its budget.
    case rateLimited = "rate_limited"
    case modelUnavailable = "model_unavailable"
    case overloaded
    case timeout
    case malformedAnswer = "malformed_answer"
    case unreachable
    case requestRejected = "request_rejected"
    case trialExhausted = "trial_exhausted"
    /// The episode needs more than one trial analysis covers.
    case trialRunBound = "trial_run_bound"
    /// The trial's allowance for the period is spent.
    case trialPaused = "trial_paused"
    case trialUnavailable = "trial_unavailable"
    /// The key was removed, replaced or unreadable before a send; nothing reached the provider.
    case keyRequired = "key_required"
}

public struct AnalysisProviderErrorClassification: Error, Sendable, Hashable {
    public var transport: AnalysisTransportError
    public var listener: AnalysisProviderFailure
    /// Google named the key free tier in this answer, whatever the classification says.
    public var freeTier: Bool

    public init(transport: AnalysisTransportError, listener: AnalysisProviderFailure, freeTier: Bool = false) {
        self.transport = transport
        self.listener = listener
        self.freeTier = freeTier
    }

    public init(_ failure: AnalysisHTTPFailure) {
        switch failure {
        case .timeout: self.init(transport: .timeout, listener: .timeout)
        case .network: self.init(transport: .network, listener: .unreachable)
        case .oversizedBody: self.init(transport: .oversizedBody, listener: .malformedAnswer)
        }
    }

    public static let invalidEncoding = AnalysisProviderErrorClassification(
        transport: .invalidEncoding,
        listener: .malformedAnswer
    )
}

extension AnalysisProviderFailure {
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
    public var windowIndex: Int? {
        switch self {
        case .adWindow(let index), .adRepair(let index): index
        case .chapters: nil
        }
    }
}
