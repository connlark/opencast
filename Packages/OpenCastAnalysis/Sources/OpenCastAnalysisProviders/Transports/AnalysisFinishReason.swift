/// A closed set, so no provider text travels in it: anything unrecognised is
/// ``malformedResponse``.
public enum AnalysisFinishReason: String, Sendable, Hashable, CaseIterable, Codable {
    case stop = "STOP"
    case maxTokens = "MAX_TOKENS"
    case safety = "SAFETY"
    case recitation = "RECITATION"
    case language = "LANGUAGE"
    case blocklist = "BLOCKLIST"
    case prohibitedContent = "PROHIBITED_CONTENT"
    case spii = "SPII"
    case imageSafety = "IMAGE_SAFETY"
    case malformedFunctionCall = "MALFORMED_FUNCTION_CALL"
    case unexpectedToolCall = "UNEXPECTED_TOOL_CALL"
    case tooManyToolCalls = "TOO_MANY_TOOL_CALLS"
    case imageProhibitedContent = "IMAGE_PROHIBITED_CONTENT"
    case imageOther = "IMAGE_OTHER"
    case noImage = "NO_IMAGE"
    case imageRecitation = "IMAGE_RECITATION"
    case missingThoughtSignature = "MISSING_THOUGHT_SIGNATURE"
    case escalation = "ESCALATION"
    case pupLimitedDisabled = "PUP_LIMITED_DISABLED"
    case continuation = "CONTINUATION"
    case unspecified = "FINISH_REASON_UNSPECIFIED"
    case other = "OTHER"
    case refusal = "REFUSAL"
    case contentFilter = "CONTENT_FILTER"
    case incomplete = "INCOMPLETE"
    case failed = "FAILED"
    /// Also any ending this list does not know.
    case malformedResponse = "MALFORMED_RESPONSE"

    public static func normalized(_ value: String?) -> AnalysisFinishReason? {
        value.map { AnalysisFinishReason(rawValue: $0) ?? .malformedResponse }
    }

    /// Gemini's `FinishReason` values as its generateContent API reference lists them.
    public static let geminiVocabulary: Set<String> = [
        "FINISH_REASON_UNSPECIFIED", "STOP", "MAX_TOKENS", "SAFETY", "RECITATION", "LANGUAGE", "OTHER", "BLOCKLIST",
        "PROHIBITED_CONTENT", "SPII", "MALFORMED_FUNCTION_CALL", "IMAGE_SAFETY", "IMAGE_PROHIBITED_CONTENT", "IMAGE_OTHER",
        "NO_IMAGE", "IMAGE_RECITATION", "UNEXPECTED_TOOL_CALL", "TOO_MANY_TOOL_CALLS", "MISSING_THOUGHT_SIGNATURE",
        "MALFORMED_RESPONSE", "ESCALATION", "PUP_LIMITED_DISABLED", "CONTINUATION",
    ]

    public static func gemini(_ value: String?) -> AnalysisFinishReason? {
        value.map { geminiVocabulary.contains($0) ? AnalysisFinishReason(rawValue: $0) ?? .malformedResponse : .malformedResponse }
    }
}
