import OpenCastAnalysis
import OpenCastAnalysisProviders

/// Messages are built from closed-vocabulary codes only, so no provider body, request text or key
/// reaches the record.
enum ChaptersSummaryFailureMapping {
    /// Free tier is read first: a final or daily 429 on such a key would otherwise read as the key
    /// refused.
    static func failure(
        _ failure: AnalysisFailure,
        listenerFailure: AnalysisProviderFailure?,
        namedFreeTier: Bool = false
    ) -> ChaptersSummaryRunFailure {
        if namedFreeTier {
            return ChaptersSummaryRunFailure(
                kind: .providerFreeTier,
                message: message(EpisodeAnalysisFailureKind.providerFreeTier.rawValue)
            )
        }
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

    static let unexpectedContract = ChaptersSummaryRunFailure(
        kind: .validationExhausted,
        message: message("unexpected_contract")
    )

    static let interrupted = ChaptersSummaryRunFailure(
        kind: .interrupted,
        message: "Chapters & Summary was interrupted."
    )

    static let runRecordUnavailable = ChaptersSummaryRunFailure(
        kind: .generic,
        message: message("run_record_unavailable")
    )

    static let providerConfiguration = ChaptersSummaryRunFailure(
        kind: .providerUnavailable,
        message: message("provider_configuration")
    )

    static func kind(for listenerFailure: AnalysisProviderFailure) -> EpisodeAnalysisFailureKind {
        switch listenerFailure {
        case .invalidKey, .billingOrQuota:
            .providerRejectedKey
        case .rateLimited, .overloaded:
            .providerLimited
        case .dailyLimit:
            .providerDailyLimit
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
