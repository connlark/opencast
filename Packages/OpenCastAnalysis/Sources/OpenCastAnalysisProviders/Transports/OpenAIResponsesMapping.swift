import OpenCastAnalysis

/// The canonical (Gemini-shaped) payload as an OpenAI Responses request,
/// and a Responses body reduced to the provider-neutral answer: the shapes
/// the evaluation harness's Responses adapter sent and read when the models
/// were qualified.
public enum OpenAIResponsesMapping {
    /// The structured-output format name per feature.
    public static func schemaName(for feature: AnalysisFeature) -> String {
        switch feature {
        case .adDetection: "podcast_ad_breaks"
        case .chaptersSummary: "podcast_chapters_summary"
        }
    }

    /// The Responses request: `instructions` from the system instruction;
    /// `input` from the turns (the first as an `input_text` part, later ones
    /// as plain text, `model` turns as `assistant`); strict `json_schema`
    /// output with every object closed; `reasoning.effort` from the request's
    /// thinking level (omitted when it has none); `max_output_tokens` from the
    /// entry; no tools, nothing stored, foreground, the default service tier
    /// and explicit prompt caching. `nil` when the payload has no user turn
    /// or no response schema. Sampling settings in the canonical payload are
    /// not sent.
    public static func body(for request: AnalysisProviderRequest) -> JSONValue? {
        body(feature: request.feature, model: request.model, payload: request.payload, thinking: request.thinking)
    }

    /// The Responses request for a canonical payload sent for `feature` on
    /// `model` at `thinking`.
    public static func body(
        feature: AnalysisFeature,
        model: AnalysisModelEntry,
        payload: JSONValue,
        thinking: String?
    ) -> JSONValue? {
        guard let contents = payload["contents"]?.arrayValue,
              let first = contents.first, let firstText = text(of: first),
              let schema = payload["generationConfig"]?["responseJsonSchema"]
        else {
            return nil
        }
        var input: [JSONValue] = [
            .object([
                "role": .string("user"),
                "content": .array([.object(["type": .string("input_text"), "text": .string(firstText)])]),
            ]),
        ]
        for message in contents.dropFirst() {
            guard let messageText = text(of: message) else { return nil }
            let role = message["role"]?.stringValue == "model" ? "assistant" : "user"
            input.append(.object(["role": .string(role), "content": .string(messageText)]))
        }
        var members = [
            JSONMember("model", .string(model.modelID)),
            JSONMember("input", .array(input)),
            JSONMember("text", .object([
                "format": .object([
                    "type": .string("json_schema"),
                    "name": .string(schemaName(for: feature)),
                    "strict": .bool(true),
                    "schema": closedSchema(schema),
                ]),
            ])),
        ]
        if let thinking {
            members.append(JSONMember("reasoning", .object(["effort": .string(thinking)])))
        }
        members += [
            JSONMember("max_output_tokens", .integer(model.maxOutputTokens)),
            JSONMember("tools", .array([])),
            JSONMember("store", .bool(false)),
            JSONMember("background", .bool(false)),
            JSONMember("service_tier", .string("default")),
            JSONMember("prompt_cache_options", .object(["mode": .string("explicit")])),
        ]
        if let instructions = payload["systemInstruction"].flatMap(text(of:)) {
            members.append(JSONMember("instructions", .string(instructions)))
        }
        return .object(members)
    }

    /// The members `/responses/input_tokens` takes from a request body.
    public static func countBody(_ body: JSONValue) -> JSONValue {
        let kept: Set<String> = ["model", "input", "instructions", "text", "tools"]
        return .object((body.objectMembers ?? []).filter { kept.contains($0.key) })
    }

    /// `schema` with `additionalProperties: false` on every object, as
    /// strict structured output requires.
    public static func closedSchema(_ schema: JSONValue) -> JSONValue {
        switch schema {
        case .array(let values):
            return .array(values.map(closedSchema))
        case .object(var members):
            members = members.map { JSONMember($0.key, closedSchema($0.value)) }
            if members.contains(where: { $0.key == "type" && $0.value == .string("object") }) {
                if let index = members.firstIndex(where: { $0.key == "additionalProperties" }) {
                    members[index].value = .bool(false)
                } else {
                    members.append(JSONMember("additionalProperties", .bool(false)))
                }
            }
            return .object(members)
        case .null, .bool, .number, .string, .unpairedSurrogateString, .unrepresentableNumber, .tooDeepContainer:
            return schema
        }
    }

    /// A Responses body as the pipeline's answer, plus the billed usage.
    /// Texts are the `output_text` parts of the `message` items, and only
    /// when the whole envelope is a finished answer: the response completed
    /// with no error or incomplete details, `output` is an array of objects,
    /// every item that reports a status completed (reasoning included),
    /// every message completed, and every message's `content` is an array
    /// of `output_text` parts. Anything else yields no texts and a finish
    /// reason other than `STOP`, always from ``AnalysisFinishReason``:
    /// `MAX_TOKENS` for `max_output_tokens`, `CONTENT_FILTER`, `REFUSAL`,
    /// `INCOMPLETE`, `FAILED`, or `MALFORMED_RESPONSE` for any shape or value
    /// it does not know. No provider string is passed through.
    public static func answer(fromBody text: String) -> (answer: AnalysisProviderAnswer, usage: AnalysisBilledUsage?) {
        // A body nested past the provider bound is refused before it is
        // parsed (what is read from it is walked level by level), so it is
        // malformed too.
        guard !ProviderJSON.refusesBody(text), let root = ProviderJSON.parse(text), case .object = root,
              let status = root["status"]?.stringValue
        else {
            return (AnalysisProviderAnswer(texts: [], finishReason: AnalysisFinishReason.malformedResponse.rawValue, usage: nil), nil)
        }
        let billed = billedUsage(root["usage"])
        let usage = billed.map(neutralUsage)
        func ended(_ reason: AnalysisFinishReason) -> (answer: AnalysisProviderAnswer, usage: AnalysisBilledUsage?) {
            (AnalysisProviderAnswer(texts: [], finishReason: reason.rawValue, usage: usage), billed)
        }
        let hasError = !ProviderJSON.isAbsent(root["error"])
        guard status == "completed", !hasError, ProviderJSON.isAbsent(root["incomplete_details"]) else {
            return ended(responseEnding(status: status, incompleteReason: root["incomplete_details"]?["reason"]?.stringValue, hasError: hasError))
        }
        guard let output = root["output"]?.arrayValue else { return ended(.malformedResponse) }
        var texts: [String] = []
        for item in output {
            guard case .object = item, let type = item["type"]?.stringValue else { return ended(.malformedResponse) }
            // Any item that reports a status must have completed; one that
            // did not makes the whole answer unfinished, whatever its type
            // and whatever the response's own status says.
            if !ProviderJSON.isAbsent(item["status"]) {
                guard let itemStatus = item["status"]?.stringValue else { return ended(.malformedResponse) }
                guard itemStatus == "completed" else { return ended(itemEnding(itemStatus)) }
            }
            guard type == "message" else { continue }
            guard item["status"]?.stringValue == "completed" else { return ended(.incomplete) }
            guard let parts = item["content"]?.arrayValue else { return ended(.malformedResponse) }
            for part in parts {
                guard case .object = part else { return ended(.malformedResponse) }
                switch part["type"]?.stringValue {
                case "output_text":
                    guard let partText = part["text"]?.stringValue else { return ended(.malformedResponse) }
                    texts.append(partText)
                case "refusal":
                    return ended(.refusal)
                default:
                    return ended(.malformedResponse)
                }
            }
        }
        // The provider bound holds for the answer texts the pipeline parses
        // next: one nested past it is malformed.
        guard !ProviderJSON.answerTooDeep(texts) else { return ended(.malformedResponse) }
        return (AnalysisProviderAnswer(texts: texts, finishReason: AnalysisFinishReason.stop.rawValue, usage: usage), billed)
    }

    /// The ending of a response that did not complete cleanly.
    static func responseEnding(status: String, incompleteReason: String?, hasError: Bool) -> AnalysisFinishReason {
        switch status {
        case "failed", "cancelled":
            return .failed
        case "in_progress", "queued":
            return .incomplete
        case "incomplete", "completed":
            if hasError { return .failed }
            switch incompleteReason {
            case "max_output_tokens": return .maxTokens
            case "content_filter": return .contentFilter
            default: return .incomplete
            }
        default:
            return .malformedResponse
        }
    }

    /// The ending of an output item that reports a status other than
    /// `completed`.
    static func itemEnding(_ status: String) -> AnalysisFinishReason {
        switch status {
        case "incomplete", "in_progress", "queued": .incomplete
        case "failed", "cancelled": .failed
        default: .malformedResponse
        }
    }

    /// `usage` as billed: `input_tokens` and `output_tokens` required,
    /// cached and cache-write input and reasoning output default to 0.
    static func billedUsage(_ usage: JSONValue?) -> AnalysisBilledUsage? {
        guard let usage, case .object = usage,
              let input = ProviderJSON.count(usage["input_tokens"]),
              let output = ProviderJSON.count(usage["output_tokens"])
        else {
            return nil
        }
        var invalid = false
        func detail(_ object: String, _ field: String) -> UInt64 {
            let value = usage[object]?[field]
            if ProviderJSON.isAbsent(value) { return 0 }
            guard let count = ProviderJSON.count(value) else {
                invalid = true
                return 0
            }
            return count
        }
        let cached = detail("input_tokens_details", "cached_tokens")
        let write = detail("input_tokens_details", "cache_write_tokens")
        let reasoning = detail("output_tokens_details", "reasoning_tokens")
        guard !invalid else { return nil }
        return AnalysisBilledUsage(input: input, cached: cached, write: write, output: output, reasoning: reasoning)
    }

    /// Billed usage in the pipeline's Gemini-shaped counts: prompt = input,
    /// candidates = output less reasoning, thoughts = reasoning, total =
    /// prompt plus the larger of output and reasoning.
    public static func neutralUsage(_ billed: AnalysisBilledUsage) -> AnalysisUsage {
        AnalysisUsage(
            promptTokenCount: billed.input,
            candidatesTokenCount: billed.output >= billed.reasoning ? billed.output - billed.reasoning : 0,
            thoughtsTokenCount: billed.reasoning,
            totalTokenCount: ProviderJSON.saturatingAdd(billed.input, max(billed.output, billed.reasoning))
        )
    }

    private static func text(of message: JSONValue) -> String? {
        message["parts"]?.arrayValue?.first?["text"]?.stringValue
    }
}
