/// The three kinds of skippable break.
public enum AdSpanKind: String, Sendable, Hashable, CaseIterable {
    case hostReadAd = "host_read_ad"
    case insertedAd = "inserted_ad"
    case houseOrNetworkPromo = "house_or_network_promo"
}

/// A verified text anchor inside one segment. The app resolves it against
/// the word timings of its own transcript.
public struct AdBoundary: Sendable, Hashable {
    public var segmentID: Int64
    public var quote: String

    public init(segmentID: Int64, quote: String) {
        self.segmentID = segmentID
        self.quote = quote
    }

    var jsonValue: JSONValue {
        .object(["segment_id": .number(.integer(segmentID)), "quote": .string(quote)])
    }
}

/// A break that passed validation, with times taken from the transcript.
public struct AdAnalysisSpan: Sendable, Hashable {
    public var kind: AdSpanKind
    public var label: String
    public var startSegmentID: Int64
    public var endSegmentID: Int64
    public var startTime: Double
    public var endTime: Double
    public var confidence: Double
    public var evidenceQuote: String
    public var startBoundary: AdBoundary?
    public var endBoundary: AdBoundary?

    var jsonValue: JSONValue {
        var members: [JSONMember] = [
            JSONMember("kind", .string(kind.rawValue)),
            JSONMember("label", .string(label)),
            JSONMember("start_segment_id", .number(.integer(startSegmentID))),
            JSONMember("end_segment_id", .number(.integer(endSegmentID))),
            JSONMember("start_time", .double(startTime)),
            JSONMember("end_time", .double(endTime)),
            JSONMember("confidence", .double(confidence)),
            JSONMember("evidence_quote", .string(evidenceQuote)),
        ]
        if let startBoundary { members.append(JSONMember("start_boundary", startBoundary.jsonValue)) }
        if let endBoundary { members.append(JSONMember("end_boundary", endBoundary.jsonValue)) }
        return .object(members)
    }
}

/// Provider token usage, summed over the calls that produced a result.
public struct AnalysisUsage: Sendable, Hashable {
    public var promptTokenCount: UInt64
    public var candidatesTokenCount: UInt64
    /// Thinking tokens, billed at the output price.
    public var thoughtsTokenCount: UInt64
    public var totalTokenCount: UInt64

    public init(
        promptTokenCount: UInt64,
        candidatesTokenCount: UInt64,
        thoughtsTokenCount: UInt64,
        totalTokenCount: UInt64
    ) {
        self.promptTokenCount = promptTokenCount
        self.candidatesTokenCount = candidatesTokenCount
        self.thoughtsTokenCount = thoughtsTokenCount
        self.totalTokenCount = totalTokenCount
    }

    /// Field-wise saturating sum; `nil` only when both are `nil`.
    public static func combine(_ lhs: AnalysisUsage?, _ rhs: AnalysisUsage?) -> AnalysisUsage? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        func add(_ a: UInt64, _ b: UInt64) -> UInt64 {
            let (sum, overflow) = a.addingReportingOverflow(b)
            return overflow ? .max : sum
        }
        return AnalysisUsage(
            promptTokenCount: add(lhs.promptTokenCount, rhs.promptTokenCount),
            candidatesTokenCount: add(lhs.candidatesTokenCount, rhs.candidatesTokenCount),
            thoughtsTokenCount: add(lhs.thoughtsTokenCount, rhs.thoughtsTokenCount),
            totalTokenCount: add(lhs.totalTokenCount, rhs.totalTokenCount)
        )
    }

    public var jsonValue: JSONValue {
        .object([
            "prompt_token_count": .number(.unsigned(promptTokenCount)),
            "candidates_token_count": .number(.unsigned(candidatesTokenCount)),
            "thoughts_token_count": .number(.unsigned(thoughtsTokenCount)),
            "total_token_count": .number(.unsigned(totalTokenCount)),
        ])
    }
}

/// A completed ad analysis: the JSON object the ad-analysis service returns
/// to the app, so the app's existing decoder, zone mapper and boundary
/// refiner consume it unchanged.
public struct AdAnalysisResponse: Sendable, Hashable {
    public var schemaVersion: UInt16
    public var requestID: String
    public var model: String
    public var policy: String
    public var policyRevision: String?
    public var spans: [AdAnalysisSpan]
    public var warnings: [String]
    public var usage: AnalysisUsage?

    public var jsonValue: JSONValue {
        var members: [JSONMember] = [
            JSONMember("schema_version", .number(.unsigned(UInt64(schemaVersion)))),
            JSONMember("request_id", .string(requestID)),
            JSONMember("model", .string(model)),
            JSONMember("policy", .string(policy)),
        ]
        if let policyRevision { members.append(JSONMember("policy_revision", .string(policyRevision))) }
        members.append(JSONMember("spans", .array(spans.map(\.jsonValue))))
        members.append(JSONMember("warnings", .array(warnings.map(JSONValue.string))))
        if let usage { members.append(JSONMember("usage", usage.jsonValue)) }
        return .object(members)
    }

    /// The response body text, byte for byte as the service writes it.
    public var jsonText: String { JSONWriter.string(jsonValue) }
}

/// The error body the ad-analysis service returns for a code, including the
/// failure category the app uses to decide when to retry.
public struct AdAnalysisErrorResponse: Sendable, Hashable {
    public enum Category: String, Sendable, Hashable {
        case capacity
        case transientTransport = "transient_transport"
        case interruptedJob = "interrupted_job"
        case validationExhausted = "validation_exhausted"
        case unsupportedInput = "unsupported_input"
    }

    public enum RetryDisposition: String, Sendable, Hashable {
        case afterCapacity = "after_capacity"
        case boundedRetry = "bounded_retry"
        case explicitRetry = "explicit_retry"
        case changedInput = "changed_input"
    }

    public var error: String
    public var category: Category?
    public var retryDisposition: RetryDisposition?
    /// The policy revision a failure is attributed to.
    public var policyRevision: String?

    public init(error: String) {
        self.error = error
        switch error {
        case "daily_request_cap_exceeded", "daily_input_token_cap_exceeded",
             "global_capacity_exhausted", "gemini_quota_exhausted":
            (category, retryDisposition) = (.capacity, .afterCapacity)
        case "ad_analysis_incomplete", "repair_feedback_exceeded":
            (category, retryDisposition) = (.validationExhausted, .explicitRetry)
        case "job_failed_transient", "job_task_failed", "ambiguous_legacy_job":
            (category, retryDisposition) = (.interruptedJob, .boundedRetry)
        case "execution_expired", "gemini_response_oversized", "gemini_response_encoding",
             "analysis_deadline_exhausted", "gemini_timeout", "gemini_unavailable",
             "gemini_retry_exhausted", "worker_fetch_error", "gemini_http_error",
             "usage_limiter_error", "admission_busy":
            (category, retryDisposition) = (.transientTransport, .boundedRetry)
        case "execution_allowance_exhausted", "invalid_execution_allowance", "too_many_segments",
             "transcript_too_large", "estimated_input_tokens_exceeded", "unsupported_schema_version",
             "body_too_large", "segment_count_exceeded", "transcript_text_too_large",
             "estimated_input_too_large", "invalid_transcript_metadata", "segment_count_mismatch",
             "empty_segments", "segment_text_too_large", "invalid_segment_timing",
             "non_monotonic_segments", "duplicate_segment_id", "metadata_field_too_large":
            (category, retryDisposition) = (.unsupportedInput, .changedInput)
        default:
            (category, retryDisposition) = (nil, nil)
        }
    }

    public var jsonValue: JSONValue {
        var members = [JSONMember("error", .string(error))]
        if let category, let retryDisposition {
            var failure: [JSONMember] = [
                JSONMember("category", .string(category.rawValue)),
                JSONMember("retry_disposition", .string(retryDisposition.rawValue)),
            ]
            if let policyRevision { failure.append(JSONMember("policy_revision", .string(policyRevision))) }
            members.append(JSONMember("failure", .object(failure)))
        }
        return .object(members)
    }
}
