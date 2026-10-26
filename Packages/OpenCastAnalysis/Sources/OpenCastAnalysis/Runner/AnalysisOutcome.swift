/// How a run ended.
public enum AnalysisOutcome: Sendable, Hashable {
    case adDetection(AdAnalysisResponse)
    case chaptersSummary(TranscriptAnalysisResponse)
    case failed(AnalysisFailure)
}

/// The failure codes a run can end with, named as the analysis services
/// name them so diagnostics and the app's retry policy read the same.
public enum AnalysisFailureCode: String, Sendable, Hashable, CaseIterable {
    /// An ad-detection window (or the whole episode) failed validation after
    /// its one repair.
    case adAnalysisIncomplete = "ad_analysis_incomplete"
    /// The corrective request could not be bounded.
    case repairFeedbackExceeded = "repair_feedback_exceeded"
    /// The run budget ran out.
    case analysisDeadlineExhausted = "analysis_deadline_exhausted"
    /// Every Chapters & Summary attempt broke a hard rule or did not parse.
    case invalidModelOutput = "invalid_model_output"
    /// The last Chapters & Summary attempt hit the output cap.
    case modelOutputTruncated = "model_output_truncated"
    /// Too many units even after coalescing.
    case transcriptTooLong = "transcript_too_long"
    case quotaExhausted = "gemini_quota_exhausted"
    case providerRejected = "gemini_http_error"
    case retryExhausted = "gemini_retry_exhausted"
    case timeout = "gemini_timeout"
    case network = "worker_fetch_error"
    case responseOversized = "gemini_response_oversized"
    case responseEncoding = "gemini_response_encoding"
    case unsupportedSchemaVersion = "unsupported_schema_version"
    case emptyRequestID = "empty_request_id"
    case emptyEpisodeID = "empty_episode_id"
    case emptyPodcastID = "empty_podcast_id"
    case transcriptNotCompleted = "transcript_not_completed"
    case metadataFieldTooLarge = "metadata_field_too_large"
    case invalidTranscriptMetadata = "invalid_transcript_metadata"
    case segmentCountMismatch = "segment_count_mismatch"
    case emptySegments = "empty_segments"
    case segmentCountExceeded = "segment_count_exceeded"
    case duplicateSegmentID = "duplicate_segment_id"
    case emptySegmentText = "empty_segment_text"
    case segmentTextTooLarge = "segment_text_too_large"
    case invalidSegmentTiming = "invalid_segment_timing"
    case nonMonotonicSegments = "non_monotonic_segments"
    case transcriptTextTooLarge = "transcript_text_too_large"
    case estimatedInputTooLarge = "estimated_input_too_large"
    /// A replay asked for an answer its archive does not hold.
    case replayMissingReply = "replay_missing_reply"
    /// The caller cancelled the run.
    case cancelled
}

/// Why a run produced no result. Carries ids and codes only, never
/// transcript text or provider bodies.
public struct AnalysisFailure: Error, Sendable, Hashable {
    public var feature: AnalysisFeature
    public var code: AnalysisFailureCode
    /// The HTTP status the service answers this failure with.
    public var status: Int
    /// For rejected Chapters & Summary answers, the comma-joined rule codes.
    public var detail: String?
    /// For ad detection, the validation issues of the failing scope.
    public var issues: [String]
    /// The failing ad-detection window; `nil` for the whole episode.
    public var windowIndex: Int?

    public init(
        feature: AnalysisFeature,
        code: AnalysisFailureCode,
        status: Int,
        detail: String? = nil,
        issues: [String] = [],
        windowIndex: Int? = nil
    ) {
        self.feature = feature
        self.code = code
        self.status = status
        self.detail = detail
        self.issues = issues
        self.windowIndex = windowIndex
    }

    /// The error body the service returns for this failure.
    public func errorJSON(policyRevision: String? = nil) -> JSONValue {
        switch feature {
        case .adDetection:
            var body = AdAnalysisErrorResponse(error: code.rawValue)
            body.policyRevision = policyRevision
            return body.jsonValue
        case .chaptersSummary:
            return TranscriptAnalysisErrorResponse(status: status, error: code.rawValue, detail: detail).jsonValue
        }
    }
}

/// The classes of ad-detection validation issue, by the prefix the service
/// gives them (`v3_boundary_receipt_mismatch:12-30` is
/// ``boundaryReceiptMismatch``).
public enum AdIssueClass: String, Sendable, Hashable, CaseIterable {
    case malformedResponse = "v3_malformed_response"
    case candidateCount = "v3_candidate_count"
    case incompleteGeneration = "v3_incomplete_generation"
    case invalidAnswerText = "v3_invalid_answer_text"
    case malformedModelJSON = "v3_malformed_model_json"
    case missingOutput = "v3_missing_output"
    case tooManyBreaks = "v3_too_many_breaks"
    case invalidKind = "v3_invalid_kind"
    case unknownBoundary = "v3_unknown_boundary"
    case invalidSpan = "v3_invalid_span"
    case boundaryReceiptMismatch = "v3_boundary_receipt_mismatch"
    case evidenceMismatch = "v3_evidence_mismatch"
    case mixedBoundaryUnresolvable = "v3_mixed_boundary_unresolvable"
    case breakDuration = "v3_break_duration"
    case coversRequest = "v3_covers_request"
    case mergedCoversRequest = "v3_merged_covers_request"
    case mergedBreakDuration = "v3_merged_break_duration"
    case adBudgetExceeded = "v3_ad_budget_exceeded"
    case repairLostCandidate = "v3_repair_lost_candidate"

    public init?(issue: String) {
        let prefix = issue.split(separator: ":", maxSplits: 1).first.map(String.init) ?? issue
        self.init(rawValue: prefix)
    }
}
