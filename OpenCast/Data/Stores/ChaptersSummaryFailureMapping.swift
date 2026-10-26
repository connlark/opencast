import OpenCastAnalysis
import OpenCastAnalysisProviders

/// The kind a failed Chapters & Summary run keeps on its record, and the
/// message beside it. Every message is built from closed-vocabulary codes,
/// so no provider body, request text or key can reach the record.
enum ChaptersSummaryFailureMapping {
    /// The listener-facing provider failure wins when the run has one; the
    /// pipeline's own code decides otherwise.
    static func failure(
        _ failure: AnalysisFailure,
        listenerFailure: AnalysisProviderFailure?
    ) -> ChaptersSummaryRunFailure {
        if let listenerFailure {
            return ChaptersSummaryRunFailure(
                kind: kind(for: listenerFailure),
                message: message(listenerFailure.rawValue)
            )
        }
        return ChaptersSummaryRunFailure(
            kind: kind(for: failure.code),
            message: message(failure.code.rawValue)
        )
    }

    static func failure(keyRequired reason: AnalysisKeyRequiredReason) -> ChaptersSummaryRunFailure {
        let kind = EpisodeAnalysisFailureKind(keyRequired: reason)
        return ChaptersSummaryRunFailure(kind: kind, message: message(kind.rawValue))
    }

    /// The answer decoded but not into the document contract.
    static let unexpectedContract = ChaptersSummaryRunFailure(
        kind: .validationExhausted,
        message: message("unexpected_contract")
    )

    /// A resume whose route, model or policy changed since it was
    /// interrupted, or that can no longer resume at all.
    static let interrupted = ChaptersSummaryRunFailure(
        kind: .interrupted,
        message: "Chapters & Summary was interrupted."
    )

    /// The run record could not be written, so nothing was sent.
    static let runRecordUnavailable = ChaptersSummaryRunFailure(
        kind: .generic,
        message: message("run_record_unavailable")
    )

    /// The policy names a provider endpoint the transports refuse.
    static let providerConfiguration = ChaptersSummaryRunFailure(
        kind: .providerUnavailable,
        message: message("provider_configuration")
    )

    static func kind(for listenerFailure: AnalysisProviderFailure) -> EpisodeAnalysisFailureKind {
        switch listenerFailure {
        case .invalidKey, .billingOrQuota:
            .providerRejectedKey
        case .rateLimited, .dailyLimit, .overloaded:
            .providerLimited
        case .modelUnavailable, .unreachable:
            .providerUnavailable
        case .timeout:
            .timedOut
        case .malformedAnswer:
            .validationExhausted
        case .requestRejected:
            .generic
        case .trialExhausted:
            EpisodeAnalysisFailureKind(keyRequired: .trialExhausted)
        case .trialPaused:
            EpisodeAnalysisFailureKind(keyRequired: .trialPaused)
        case .trialRunBound:
            EpisodeAnalysisFailureKind(keyRequired: .trialRunBound)
        case .trialUnavailable:
            EpisodeAnalysisFailureKind(keyRequired: .proxyUnavailable)
        case .keyRequired:
            EpisodeAnalysisFailureKind(keyRequired: .noKey)
        }
    }

    /// Codes the Chapters engine can emit when no provider failure explains
    /// the run; the ad-only codes map to `generic` for completeness.
    static func kind(for code: AnalysisFailureCode) -> EpisodeAnalysisFailureKind {
        switch code {
        case .invalidModelOutput, .modelOutputTruncated, .responseOversized, .responseEncoding,
             .transcriptTooLong, .transcriptTextTooLarge, .estimatedInputTooLarge:
            .validationExhausted
        case .timeout, .analysisDeadlineExhausted:
            .timedOut
        case .network:
            .providerUnavailable
        case .retryExhausted, .quotaExhausted, .providerRejected:
            .serviceUnavailable
        case .adAnalysisIncomplete, .repairFeedbackExceeded, .unsupportedSchemaVersion, .emptyRequestID,
             .emptyEpisodeID, .emptyPodcastID, .transcriptNotCompleted, .metadataFieldTooLarge,
             .invalidTranscriptMetadata, .segmentCountMismatch, .emptySegments, .segmentCountExceeded,
             .duplicateSegmentID, .emptySegmentText, .segmentTextTooLarge, .invalidSegmentTiming,
             .nonMonotonicSegments, .replayMissingReply, .cancelled:
            .generic
        }
    }

    private static func message(_ code: String) -> String {
        "Chapters & Summary failed (\(code))."
    }
}
