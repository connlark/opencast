/// The replay oracle's Swift side: builds, validates and runs exactly what
/// the pipeline would for recorded answers, and reports it in the JSON
/// shapes the services' eval bridges print, so the two compare field by
/// field. Used by `OpenCastAnalysisReplay` and the parity tests.
public enum AnalysisReplay {
    public struct InputError: Error, Sendable, CustomStringConvertible {
        public let description: String

        public init(description: String) {
            self.description = description
        }
    }

    /// `{"texts": [...], "finish_reason": ..., "usage": {...}}`
    public static func providerAnswer(_ value: JSONValue) throws(InputError) -> AnalysisProviderAnswer {
        var texts: [String] = []
        for element in value["texts"]?.arrayValue ?? [] {
            guard let text = element.stringValue else { throw InputError(description: "answer texts must be strings") }
            texts.append(text)
        }
        var usage: AnalysisUsage?
        if let usageValue = value["usage"], usageValue != .null {
            func count(_ key: String) -> UInt64 {
                if case .number(.unsigned(let number))? = usageValue[key] { return number }
                return 0
            }
            usage = AnalysisUsage(
                promptTokenCount: count("prompt_token_count"),
                candidatesTokenCount: count("candidates_token_count"),
                thoughtsTokenCount: count("thoughts_token_count"),
                totalTokenCount: count("total_token_count")
            )
        }
        return AnalysisProviderAnswer(texts: texts, finishReason: value["finish_reason"]?.stringValue, usage: usage)
    }

    /// `{"body": "..."}`, `{"answer": {...}}`, or `null` for not recorded.
    public static func reply(_ value: JSONValue) throws(InputError) -> AnalysisProviderReply? {
        if value == .null { return nil }
        if let body = value["body"]?.stringValue { return .geminiBody(body) }
        if let answer = value["answer"] { return .answer(try providerAnswer(answer)) }
        throw InputError(description: "a reply is {\"body\": ...} or {\"answer\": ...}")
    }

    /// Replies keyed `window-N`, `repair-N` or `attempt-N`.
    public static func replies(_ value: JSONValue) throws(InputError) -> [AnalysisProviderRequest.Purpose: AnalysisProviderReply] {
        guard let members = value.objectMembers else { throw InputError(description: "replies must be an object") }
        var result: [AnalysisProviderRequest.Purpose: AnalysisProviderReply] = [:]
        for member in members {
            let parts = member.key.split(separator: "-")
            guard parts.count == 2, let index = Int(parts[1]) else {
                throw InputError(description: "bad reply key \(member.key)")
            }
            let purpose: AnalysisProviderRequest.Purpose
            switch parts[0] {
            case "window": purpose = .adWindow(index: index)
            case "repair": purpose = .adRepair(index: index)
            case "attempt": purpose = .chapters(attempt: index)
            default: throw InputError(description: "bad reply key \(member.key)")
            }
            if let reply = try reply(member.value) { result[purpose] = reply }
        }
        return result
    }

    /// The pipeline's view of every scalar in the shape of the ad bridge's
    /// `char_classes` op: alphanumeric and whitespace ranges, and the
    /// scalars whose receipt token differs from themselves.
    public static func characterClasses() -> JSONValue {
        func appendRange(_ ranges: inout [[UInt32]], _ value: UInt32) {
            if let last = ranges.last, last[1] + 1 == value {
                ranges[ranges.count - 1][1] = value
            } else {
                ranges.append([value, value])
            }
        }
        var alphanumeric: [[UInt32]] = []
        var whitespace: [[UInt32]] = []
        var lowercase: [JSONValue] = []
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let text = String(scalar)
            if let token = RustText.normalizedReceiptTokens(text).first {
                appendRange(&alphanumeric, value)
                if !RustText.same(token, text) {
                    lowercase.append(.array([
                        .number(.unsigned(UInt64(value))),
                        .array(token.unicodeScalars.map { .number(.unsigned(UInt64($0.value))) }),
                    ]))
                }
            }
            if RustText.isBlank(text) { appendRange(&whitespace, value) }
        }
        func ranges(_ list: [[UInt32]]) -> JSONValue {
            .array(list.map { .array($0.map { .number(.unsigned(UInt64($0))) }) })
        }
        return .object([
            "alphanumeric": ranges(alphanumeric),
            "whitespace": ranges(whitespace),
            "lowercase": .array(lowercase),
        ])
    }

    public static func renderAds(
        _ request: AdAnalysisRequest,
        policy: AdDetectionAnalysisPolicy,
        canonicalThinking: String?
    ) -> JSONValue {
        let windows = AdWindowing.windows(of: request, policy: policy.settings)
        return .object(["windows": .array(windows.enumerated().map { index, window in
            .object([
                "index": .integer(index),
                "payload": AdCanonicalPayload.payload(
                    window,
                    policy: policy.settings,
                    maxOutputTokens: policy.model.maxOutputTokens,
                    thinking: canonicalThinking
                ),
            ])
        })])
    }

    public static func renderChapters(_ request: TranscriptAnalysisRequest, policy analysisPolicy: ChaptersSummaryAnalysisPolicy) -> JSONValue {
        let policy = analysisPolicy.settings
        let model = analysisPolicy.model
        var requestError = JSONValue.null
        var estimate = JSONValue.null
        switch AnalysisRequestValidation.validate(request, policy: policy) {
        case .failure(let error): requestError = .string(error.code)
        case .success(let tokens): estimate = .number(.unsigned(tokens))
        }
        switch ChaptersPreparation.prepare(request, policy: policy) {
        case .failure(let error):
            return .object([
                "request_error": requestError, "estimated_input_tokens": estimate, "error": .string(error.code),
                "coalesced": .null, "model_request": .null, "remap": .null, "base_level": .null, "payloads": .null,
            ])
        case .success(let prepared):
            let base = ChaptersCanonicalPayload.baseThinking(
                modelSegmentCount: prepared.modelRequest.segments.count,
                model: model,
                policy: policy
            )
            func payload(_ level: String) -> JSONValue {
                ChaptersCanonicalPayload.payload(
                    prepared.modelRequest,
                    policy: policy,
                    maxOutputTokens: model.maxOutputTokens,
                    thinking: level
                )
            }
            return .object([
                "request_error": requestError,
                "estimated_input_tokens": estimate,
                "error": .null,
                "coalesced": .bool(prepared.remap != nil),
                "model_request": prepared.modelRequest.jsonValue,
                "remap": prepared.remap.map { remap in
                    .array(remap.map {
                        .array([.number(.integer($0.originalStartID)), .number(.integer($0.originalEndID))])
                    })
                } ?? .null,
                "base_level": .string(base),
                "payloads": .object(["base": payload(base), "high": payload(ChaptersPipelineConstants.escalatedThinking)]),
            ])
        }
    }

    public static func validateAds(
        _ request: AdAnalysisRequest,
        reply: AnalysisProviderReply,
        window: Bool,
        policy: AdDetectionAnalysisPolicy
    ) -> JSONValue {
        let policy = policy.settings
        let parsed = switch reply {
        case .geminiBody(let body): AdAnswerParser.parse(geminiBody: body)
        case .answer(let answer): AdAnswerParser.parse(answer: answer)
        }
        let validation = parsed.output.map { output in
            window
                ? AdValidator.validateWindow(request, output, policy: policy)
                : AdValidator.validate(request, output, policy: policy)
        } ?? AdValidation(issues: [parsed.issue ?? "v3_missing_output"])
        return .object(["parse": AnalysisTraceJSON.parsed(parsed), "validation": AnalysisTraceJSON.validation(validation)])
    }

    public static func validateChapters(
        _ request: TranscriptAnalysisRequest,
        reply: AnalysisProviderReply,
        policy: ChaptersSummaryAnalysisPolicy
    ) -> JSONValue {
        let policy = policy.settings
        let parsed = switch reply {
        case .geminiBody(let body): ChaptersAnswerParser.parse(geminiBody: body)
        case .answer(let answer): ChaptersAnswerParser.parse(answer: answer)
        }
        guard let output = parsed.output else { return AnalysisTraceJSON.chaptersParsed(parsed, result: nil) }
        switch ChaptersPreparation.prepare(request, policy: policy) {
        case .failure(let error):
            let base = AnalysisTraceJSON.chaptersParsed(parsed, result: nil)
            return .object(["parse": base["parse"] ?? .null, "result": .object(["error": .string(error.code)])])
        case .success(let prepared):
            let result = ChaptersValidator.validateAndRemap(
                original: request,
                prepared: prepared,
                output: output,
                policy: policy
            )
            return AnalysisTraceJSON.chaptersParsed(parsed, result: result)
        }
    }

    /// Every window's trace, the run result and the exact response text.
    /// The trace analyzes every window; the result comes from
    /// ``AnalysisRunner/detectAds(_:model:)``.
    public static func runAds(
        _ request: AdAnalysisRequest,
        replies: [AnalysisProviderRequest.Purpose: AnalysisProviderReply],
        policy: AdDetectionAnalysisPolicy,
        canonicalThinking: String?
    ) async -> JSONValue {
        let runner = AnalysisRunner(transport: AnalysisReplayTransport(replies: replies), clock: AnalysisFrozenClock())
        let traces = await runner.traceAdWindows(request, policy: policy, canonicalThinking: canonicalThinking)
        let outcome = await runner.detectAds(request, policy: policy, canonicalThinking: canonicalThinking)
        var responseJSON = JSONValue.null
        if case .adDetection(let response) = outcome { responseJSON = .string(response.jsonText) }
        return .object([
            "windows": .array(traces.map(AnalysisTraceJSON.window)),
            "result": AnalysisTraceJSON.adResult(outcome),
            "response_json": responseJSON,
        ])
    }

    /// Each attempt that got a reply, the result and the exact response text.
    public static func runChapters(
        _ request: TranscriptAnalysisRequest,
        replies: [AnalysisProviderRequest.Purpose: AnalysisProviderReply],
        policy: ChaptersSummaryAnalysisPolicy
    ) async -> JSONValue {
        let runner = AnalysisRunner(transport: AnalysisReplayTransport(replies: replies), clock: AnalysisFrozenClock())
        let (outcome, attempts) = await runner.traceChapters(request, policy: policy)
        var responseJSON = JSONValue.null
        if case .chaptersSummary(let response) = outcome { responseJSON = .string(response.jsonText) }
        return .object([
            "attempts": .array(attempts.map { attempt in
                .object([
                    "attempt": .integer(attempt.attempt),
                    "level": .string(attempt.thinking),
                    "payload": attempt.payload,
                    "validate": AnalysisTraceJSON.chaptersParsed(attempt.parsed, result: attempt.result),
                ])
            }),
            "result": AnalysisTraceJSON.chaptersResult(outcome),
            "response_json": responseJSON,
        ])
    }
}
