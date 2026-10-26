/// The parts of a Gemini `generateContent` body the pipelines read, with
/// the service's tolerance: unknown fields are ignored, absent fields take
/// their defaults, and present fields must have the right type.
struct GeminiResponse {
    struct Part {
        var text: String
        var thought: Bool
    }

    struct Candidate {
        /// `nil` when the candidate has no `content`.
        var parts: [Part]?
        var finishReason: String?
    }

    var candidates: [Candidate]
    var usage: AnalysisUsage?

    /// - Parameter readsThought: whether parts carry a typed `thought` flag
    ///   (the ad pipeline reads it; the chapters pipeline ignores the field).
    init(text: String, readsThought: Bool) throws {
        let root = try StrictDecoding.fields(
            try JSONParser.parse(text),
            .init(fields: ["candidates", "usageMetadata"], defaulted: ["candidates", "usageMetadata"])
        )
        candidates = []
        if let value = root["candidates"] {
            for element in try StrictDecoding.array(value) {
                candidates.append(try Self.candidate(element, readsThought: readsThought))
            }
        }
        usage = try StrictDecoding.optional(root["usageMetadata"], Self.usage)
    }

    static func candidate(_ value: JSONValue, readsThought: Bool) throws(StrictDecodingError) -> Candidate {
        let fields = try StrictDecoding.fields(
            value,
            .init(fields: ["content", "finishReason"], defaulted: ["content", "finishReason"])
        )
        let parts = try StrictDecoding.optional(fields["content"]) { content throws(StrictDecodingError) in
            let contentFields = try StrictDecoding.fields(
                content,
                .init(fields: ["parts"], defaulted: ["parts"])
            )
            var parts: [Part] = []
            if let list = contentFields["parts"] {
                for element in try StrictDecoding.array(list) {
                    let names = readsThought ? ["text", "thought"] : ["text"]
                    let partFields = try StrictDecoding.fields(
                        element,
                        .init(fields: names, defaulted: Set(names))
                    )
                    parts.append(Part(
                        text: try partFields["text"].map(StrictDecoding.string) ?? "",
                        thought: try partFields["thought"].map(StrictDecoding.bool) ?? false
                    ))
                }
            }
            return parts
        }
        return Candidate(
            parts: parts,
            finishReason: try StrictDecoding.optional(fields["finishReason"], StrictDecoding.string)
        )
    }

    /// `usageMetadata`, with the total raised to at least the sum of its
    /// parts for providers that report thinking separately.
    static func usage(_ value: JSONValue) throws(StrictDecodingError) -> AnalysisUsage {
        let names = ["promptTokenCount", "candidatesTokenCount", "thoughtsTokenCount", "totalTokenCount"]
        let fields = try StrictDecoding.fields(value, .init(fields: names, defaulted: Set(names)))
        func count(_ name: String) throws(StrictDecodingError) -> UInt64 {
            try fields[name].map(StrictDecoding.uint64) ?? 0
        }
        let prompt = try count("promptTokenCount")
        let candidates = try count("candidatesTokenCount")
        let thoughts = try count("thoughtsTokenCount")
        let total = try count("totalTokenCount")
        let sum = AnalysisUsage.saturatingSum(prompt, candidates, thoughts)
        return AnalysisUsage(
            promptTokenCount: prompt,
            candidatesTokenCount: candidates,
            thoughtsTokenCount: thoughts,
            totalTokenCount: max(total, sum)
        )
    }
}

extension AnalysisUsage {
    /// The total raised to at least the sum of its parts, for providers that
    /// report thinking separately.
    var guardedTotal: AnalysisUsage {
        var usage = self
        usage.totalTokenCount = max(totalTokenCount, Self.saturatingSum(promptTokenCount, candidatesTokenCount, thoughtsTokenCount))
        return usage
    }

    static func saturatingSum(_ values: UInt64...) -> UInt64 {
        values.reduce(0) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(value)
            return overflow ? .max : sum
        }
    }
}
