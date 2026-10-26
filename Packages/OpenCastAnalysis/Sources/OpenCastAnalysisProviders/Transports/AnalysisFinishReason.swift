/// How a provider answer ended, as send records, logs, the OpenAI answer and
/// the Gemini body the pipeline reads carry it: a closed set, so no provider
/// text travels in it. Gemini's documented values keep their names; OpenAI
/// endings map onto `STOP` and `MAX_TOKENS` or onto the few cases added
/// here; anything unrecognised is ``malformedResponse``.
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
    /// The model refused in a message part.
    case refusal = "REFUSAL"
    /// The provider's content filter ended the answer.
    case contentFilter = "CONTENT_FILTER"
    /// The answer, or an item of it, did not finish, for no reason given
    /// here.
    case incomplete = "INCOMPLETE"
    /// The provider reports the response failed or was cancelled.
    case failed = "FAILED"
    /// The body is not the provider's answer shape, or its ending is not
    /// one this list knows.
    case malformedResponse = "MALFORMED_RESPONSE"

    /// `value` when it is one of these names exactly, otherwise
    /// ``malformedResponse``; `nil` stays `nil`.
    public static func normalized(_ value: String?) -> AnalysisFinishReason? {
        value.map { AnalysisFinishReason(rawValue: $0) ?? .malformedResponse }
    }

    /// Gemini's `FinishReason` values as its API reference lists them
    /// (generateContent, read 2026-10-24).
    public static let geminiVocabulary: Set<String> = [
        "FINISH_REASON_UNSPECIFIED", "STOP", "MAX_TOKENS", "SAFETY", "RECITATION", "LANGUAGE", "OTHER", "BLOCKLIST",
        "PROHIBITED_CONTENT", "SPII", "MALFORMED_FUNCTION_CALL", "IMAGE_SAFETY", "IMAGE_PROHIBITED_CONTENT", "IMAGE_OTHER",
        "NO_IMAGE", "IMAGE_RECITATION", "UNEXPECTED_TOOL_CALL", "TOO_MANY_TOOL_CALLS", "MISSING_THOUGHT_SIGNATURE",
        "MALFORMED_RESPONSE", "ESCALATION", "PUP_LIMITED_DISABLED", "CONTINUATION",
    ]

    /// A Gemini candidate's `finishReason`: the documented value, or
    /// ``malformedResponse`` for anything Gemini does not document;
    /// `nil` stays `nil`.
    public static func gemini(_ value: String?) -> AnalysisFinishReason? {
        value.map { geminiVocabulary.contains($0) ? AnalysisFinishReason(rawValue: $0) ?? .malformedResponse : .malformedResponse }
    }
}
