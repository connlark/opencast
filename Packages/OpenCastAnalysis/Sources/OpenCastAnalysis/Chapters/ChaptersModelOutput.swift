/// The model's Chapters & Summary answer before validation. Unknown fields
/// are tolerated; missing fields, wrong types and floats in id fields reject
/// the answer.
public struct ChaptersModelOutput: Sendable, Hashable {
    public struct Chapter: Sendable, Hashable {
        public var title: String
        public var startSegmentID: Int64
        public var endSegmentID: Int64
        public var confidence: Double
    }

    public struct Claim: Sendable, Hashable {
        public var text: String
        public var evidenceSegmentID: Int64
    }

    public struct Summary: Sendable, Hashable {
        public var summary: String
        public var oneLineDescription: String
        public var claims: [Claim]
    }

    public var chapters: [Chapter]
    public var summary: Summary

    init(chapters: [Chapter], summary: Summary) {
        self.chapters = chapters
        self.summary = summary
    }

    public init(json: JSONValue) throws(StrictDecodingError) {
        let fields = try StrictDecoding.fields(json, .init(fields: ["chapters", "summary"]))
        var chapters: [Chapter] = []
        for element in try StrictDecoding.array(fields["chapters"]!) {
            let chapter = try StrictDecoding.fields(
                element,
                .init(fields: ["title", "start_segment_id", "end_segment_id", "confidence"])
            )
            chapters.append(Chapter(
                title: try StrictDecoding.string(chapter["title"]!),
                startSegmentID: try StrictDecoding.int64(chapter["start_segment_id"]!),
                endSegmentID: try StrictDecoding.int64(chapter["end_segment_id"]!),
                confidence: try StrictDecoding.double(chapter["confidence"]!)
            ))
        }
        let summaryFields = try StrictDecoding.fields(
            fields["summary"]!,
            .init(fields: ["summary", "one_line_description", "claims"])
        )
        var claims: [Claim] = []
        for element in try StrictDecoding.array(summaryFields["claims"]!) {
            let claim = try StrictDecoding.fields(element, .init(fields: ["text", "evidence_segment_id"]))
            claims.append(Claim(
                text: try StrictDecoding.string(claim["text"]!),
                evidenceSegmentID: try StrictDecoding.int64(claim["evidence_segment_id"]!)
            ))
        }
        self.chapters = chapters
        self.summary = Summary(
            summary: try StrictDecoding.string(summaryFields["summary"]!),
            oneLineDescription: try StrictDecoding.string(summaryFields["one_line_description"]!),
            claims: claims
        )
    }
}

/// A Chapters & Summary answer reduced to what validation needs.
public struct ChaptersParsedAnswer: Sendable, Hashable {
    public var output: ChaptersModelOutput?
    public var usage: AnalysisUsage?
    /// `gemini_finish_reason:<reason>` for a non-STOP finish.
    public var warnings: [String]
    /// The parse failure code when there is no output.
    public var failure: String?
}

/// Reads one answer the way the Chapters & Summary service does. A
/// MAX_TOKENS finish is a hard failure (a truncated schema-constrained
/// answer can still be a valid JSON prefix), as is any other non-STOP
/// finish.
public enum ChaptersAnswerParser {
    public static let malformedResponse = "malformed_gemini_response"
    public static let missingText = "missing_gemini_text"
    public static let malformedModelJSON = "malformed_model_json"
    public static let truncated = "max_tokens_truncated"
    public static let nonStopFinish = "non_stop_finish_reason"

    public static func parse(geminiBody body: String) -> ChaptersParsedAnswer {
        guard let response = try? GeminiResponse(text: body, readsThought: false) else {
            return ChaptersParsedAnswer(output: nil, usage: nil, warnings: [], failure: malformedResponse)
        }
        guard let candidate = response.candidates.first else {
            return ChaptersParsedAnswer(output: nil, usage: response.usage, warnings: [], failure: missingText)
        }
        return finish(
            texts: (candidate.parts ?? []).map(\.text),
            finishReason: candidate.finishReason,
            usage: response.usage
        )
    }

    public static func parse(answer: AnalysisProviderAnswer) -> ChaptersParsedAnswer {
        finish(texts: answer.texts, finishReason: answer.finishReason, usage: answer.usage.map(\.guardedTotal))
    }

    private static func finish(texts: [String], finishReason: String?, usage: AnalysisUsage?) -> ChaptersParsedAnswer {
        var warnings: [String] = []
        if let finishReason, !RustText.same(finishReason, "STOP") {
            warnings.append("gemini_finish_reason:\(finishReason)")
            return ChaptersParsedAnswer(
                output: nil,
                usage: usage,
                warnings: warnings,
                failure: RustText.same(finishReason, "MAX_TOKENS") ? truncated : nonStopFinish
            )
        }
        let text = texts.joined()
        guard !RustText.isBlank(text) else {
            return ChaptersParsedAnswer(output: nil, usage: usage, warnings: warnings, failure: missingText)
        }
        guard let json = try? JSONParser.parse(RustText.trim(text)),
              let output = try? ChaptersModelOutput(json: json)
        else {
            return ChaptersParsedAnswer(output: nil, usage: usage, warnings: warnings, failure: malformedModelJSON)
        }
        return ChaptersParsedAnswer(output: output, usage: usage, warnings: warnings, failure: nil)
    }
}
