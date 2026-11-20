public struct AdParsedAnswer: Sendable, Hashable {
    public var output: AdModelOutput?
    public var usage: AnalysisUsage?
    /// Why there is no output; `nil` exactly when `output` is present.
    public var issue: String?
}

/// A truncated answer can still be valid JSON, so any finish other than STOP rejects it.
public enum AdAnswerParser {
    /// Largest answer text accepted, in UTF-8 bytes.
    public static let maxAnswerBytes = 100_000

    public static func parse(geminiBody body: String) -> AdParsedAnswer {
        var result = AdParsedAnswer(output: nil, usage: nil, issue: "v3_malformed_response")
        guard let response = try? GeminiResponse(text: body, readsThought: true) else { return result }
        result.usage = response.usage
        guard response.candidates.count == 1 else {
            result.issue = "v3_candidate_count"
            return result
        }
        let candidate = response.candidates[0]
        guard RustText.same(candidate.finishReason, "STOP") else {
            result.issue = "v3_incomplete_generation"
            return result
        }
        let texts = (candidate.parts ?? [])
            .filter { !$0.thought && !RustText.isBlank($0.text) }
            .map(\.text)
        return finish(texts: texts, usage: result.usage)
    }

    public static func parse(answer: AnalysisProviderAnswer) -> AdParsedAnswer {
        let usage = answer.usage.map(\.guardedTotal)
        guard RustText.same(answer.finishReason, "STOP") else {
            return AdParsedAnswer(output: nil, usage: usage, issue: "v3_incomplete_generation")
        }
        return finish(texts: answer.texts.filter { !RustText.isBlank($0) }, usage: usage)
    }

    private static func finish(texts: [String], usage: AnalysisUsage?) -> AdParsedAnswer {
        guard texts.count == 1, texts[0].utf8.count <= maxAnswerBytes else {
            return AdParsedAnswer(output: nil, usage: usage, issue: "v3_invalid_answer_text")
        }
        guard let output = try? AdModelOutput(text: texts[0]) else {
            return AdParsedAnswer(output: nil, usage: usage, issue: "v3_malformed_model_json")
        }
        return AdParsedAnswer(output: output, usage: usage, issue: nil)
    }
}
