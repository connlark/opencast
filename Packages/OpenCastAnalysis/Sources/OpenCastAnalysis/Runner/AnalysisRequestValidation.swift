/// The request checks the analysis services apply before any model call.
/// Each failure is the service's error code.
public enum AnalysisRequestValidation {
    static let maxAdSegments = 6_000
    static let maxTranscriptTextCharacters = 360_000
    static let maxSegmentTextCharacters = 2_000
    static let maxEstimatedInputTokens: UInt64 = 120_000
    static let promptOverheadCharacters = 8_000
    static let maxRequestIDCharacters = 256
    static let maxEpisodeIDCharacters = 128
    static let maxPodcastIDCharacters = 2_048
    static let maxTitleCharacters = 512
    static let maxLanguageCodeCharacters = 40

    /// Validates an ad-detection request; returns the estimated input tokens.
    public static func validate(_ request: AdAnalysisRequest) -> Result<UInt64, AnalysisCodeError> {
        if let code = commonCode(
            schemaVersion: request.schemaVersion,
            requestID: request.requestID,
            episodeID: request.episodeID,
            podcastID: request.podcastID,
            episodeTitle: request.episodeTitle,
            podcastTitle: request.podcastTitle,
            languageCode: request.transcript.languageCode,
            fingerprint: request.transcript.fingerprint,
            updatedAt: request.transcript.updatedAt,
            state: request.transcript.state,
            audioDuration: request.transcript.audioDuration,
            segmentCount: request.transcript.segmentCount,
            segments: request.segments
        ) {
            return .failure(AnalysisCodeError(code))
        }
        if request.segments.count > maxAdSegments { return .failure(AnalysisCodeError("segment_count_exceeded")) }
        switch segmentTotals(request.segments) {
        case .failure(let error):
            return .failure(error)
        case .success(let textCharacters):
            if textCharacters > maxTranscriptTextCharacters {
                return .failure(AnalysisCodeError("transcript_text_too_large"))
            }
            let framing = request.segments.reduce(0) { $0 + framingCharacters($1) }
            let estimate = estimateTokens(characters: textCharacters + promptOverheadCharacters + framing)
            if estimate > maxEstimatedInputTokens {
                return .failure(AnalysisCodeError("estimated_input_too_large"))
            }
            return .success(estimate)
        }
    }

    /// Validates a Chapters & Summary request against the model-facing view
    /// (coalesced when long); returns the estimated input tokens.
    public static func validate(
        _ request: TranscriptAnalysisRequest,
        policy: ChaptersSummaryPolicy
    ) -> Result<UInt64, AnalysisCodeError> {
        if let code = commonCode(
            schemaVersion: request.schemaVersion,
            requestID: request.requestID,
            episodeID: request.episodeID,
            podcastID: request.podcastID,
            episodeTitle: request.episodeTitle,
            podcastTitle: request.podcastTitle,
            languageCode: request.transcript.languageCode,
            fingerprint: request.transcript.fingerprint,
            updatedAt: request.transcript.updatedAt,
            state: request.transcript.state,
            audioDuration: request.transcript.audioDuration,
            segmentCount: request.transcript.segmentCount,
            segments: request.segments
        ) {
            return .failure(AnalysisCodeError(code))
        }
        switch segmentTotals(request.segments) {
        case .failure(let error):
            return .failure(error)
        case .success(let textCharacters):
            if textCharacters > maxTranscriptTextCharacters {
                return .failure(AnalysisCodeError("transcript_text_too_large"))
            }
        }
        let prepared: ChaptersPreparedRequest
        switch ChaptersPreparation.prepare(request, policy: policy) {
        case .failure(let error): return .failure(error)
        case .success(let value): prepared = value
        }
        let modelSegments = prepared.modelRequest.segments
        let text = modelSegments.reduce(0) { $0 + RustText.charCount($1.text) }
        let framing = modelSegments.reduce(0) { $0 + framingCharacters($1) }
        let estimate = estimateTokens(characters: text + promptOverheadCharacters + framing)
        if estimate > maxEstimatedInputTokens {
            return .failure(AnalysisCodeError("estimated_input_too_large"))
        }
        return .success(estimate)
    }

    private static func commonCode(
        schemaVersion: UInt16,
        requestID: String,
        episodeID: String,
        podcastID: String,
        episodeTitle: String?,
        podcastTitle: String?,
        languageCode: String,
        fingerprint: String,
        updatedAt: String,
        state: String,
        audioDuration: Double,
        segmentCount: Int,
        segments: [AnalysisSegment]
    ) -> String? {
        if schemaVersion != 1 { return "unsupported_schema_version" }
        if RustText.isBlank(requestID) { return "empty_request_id" }
        if RustText.isBlank(episodeID) { return "empty_episode_id" }
        if RustText.isBlank(podcastID) { return "empty_podcast_id" }
        if !RustText.same(state, "completed") { return "transcript_not_completed" }
        if RustText.charCount(requestID) > maxRequestIDCharacters
            || RustText.charCount(episodeID) > maxEpisodeIDCharacters
            || RustText.charCount(podcastID) > maxPodcastIDCharacters
            || RustText.charCount(languageCode) > maxLanguageCodeCharacters
            || episodeTitle.map({ RustText.charCount($0) > maxTitleCharacters }) == true
            || podcastTitle.map({ RustText.charCount($0) > maxTitleCharacters }) == true {
            return "metadata_field_too_large"
        }
        if RustText.isBlank(languageCode) || RustText.isBlank(fingerprint) || RustText.isBlank(updatedAt)
            || !(audioDuration.isFinite && audioDuration > 0) {
            return "invalid_transcript_metadata"
        }
        if segmentCount != segments.count { return "segment_count_mismatch" }
        if segments.isEmpty { return "empty_segments" }
        return nil
    }

    /// Per-segment checks in order; the total text characters on success.
    private static func segmentTotals(_ segments: [AnalysisSegment]) -> Result<Int, AnalysisCodeError> {
        var seen = Set<Int64>()
        var previousEnd: Double?
        var total = 0
        for segment in segments {
            guard seen.insert(segment.id).inserted else { return .failure(AnalysisCodeError("duplicate_segment_id")) }
            let length = RustText.charCount(segment.text)
            if RustText.isBlank(segment.text) { return .failure(AnalysisCodeError("empty_segment_text")) }
            if length > maxSegmentTextCharacters { return .failure(AnalysisCodeError("segment_text_too_large")) }
            guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0, segment.end >= segment.start else {
                return .failure(AnalysisCodeError("invalid_segment_timing"))
            }
            if let previousEnd, segment.start + 0.001 < previousEnd {
                return .failure(AnalysisCodeError("non_monotonic_segments"))
            }
            previousEnd = segment.end
            total += length
        }
        return .success(total)
    }

    /// `[id | start-end] ` plus the newline, as the services' prompt framing
    /// counts it.
    static func framingCharacters(_ segment: AnalysisSegment) -> Int {
        RustText.charCount(
            "[\(segment.id) | \(RustFloatFormat.fixed(segment.start, places: 3))-\(RustFloatFormat.fixed(segment.end, places: 3))] \n"
        )
    }

    static func estimateTokens(characters: Int) -> UInt64 {
        (UInt64(characters) + 3) / 4
    }
}
