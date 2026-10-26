/// JSON forms of results and traces in the shapes the services' replay
/// oracles print, so the two sides compare field by field.
public enum AnalysisTraceJSON {
    public static func usage(_ usage: AnalysisUsage?) -> JSONValue {
        usage?.jsonValue ?? .null
    }

    public static func validation(_ validation: AdValidation) -> JSONValue {
        .object([
            "complete": .bool(validation.isComplete),
            "spans": .array(validation.spans.map(\.jsonValue)),
            "warnings": .array(validation.issues.map(JSONValue.string)),
            "notices": .array(validation.notices.map(JSONValue.string)),
        ])
    }

    public static func parsed(_ parsed: AdParsedAnswer) -> JSONValue {
        .object([
            "issue": parsed.issue.map(JSONValue.string) ?? .null,
            "usage": usage(parsed.usage),
            "output": parsed.output?.jsonValue ?? .null,
        ])
    }

    public static func window(_ trace: AdWindowTrace) -> JSONValue {
        var initial = JSONValue.null
        if let attempt = trace.initial {
            initial = .object([
                "issue": attempt.parsed.issue.map(JSONValue.string) ?? .null,
                "usage": usage(attempt.parsed.usage),
                "output": attempt.parsed.output?.jsonValue ?? .null,
                "validation": attempt.validation.map(validation) ?? .null,
            ])
        }
        var repair = JSONValue.null
        if let payload = trace.repairPayload {
            var payloadValue = JSONValue.null
            var payloadError = JSONValue.null
            switch payload {
            case .success(let value): payloadValue = value
            case .failure(let error): payloadError = .string(error.code)
            }
            let attempt = trace.repair
            repair = .object([
                "payload": payloadValue,
                "payload_error": payloadError,
                "reply": .bool(attempt != nil),
                "issue": attempt?.parsed.issue.map(JSONValue.string) ?? .null,
                "usage": usage(attempt?.parsed.usage),
                "output": attempt?.parsed.output?.jsonValue ?? .null,
                "validation": attempt?.validation.map(validation) ?? .null,
            ])
        }
        let outcome: JSONValue
        switch trace.result {
        case .success(let result)?:
            outcome = .object([
                "status": .string("ok"),
                "code": .null,
                "issues": .array([]),
                "notices": .array(result.notices.map(JSONValue.string)),
                "usage": usage(result.usage),
            ])
        case .failure(let failure)?:
            let spent = trace.initial.map { AnalysisUsage.combine($0.parsed.usage, trace.repair?.parsed.usage) } ?? nil
            outcome = .object([
                "status": .string("failed"),
                "code": .string(failure.code.rawValue),
                "issues": .array(failure.issues.map(JSONValue.string)),
                "notices": .array([]),
                "usage": usage(spent),
            ])
        case nil:
            outcome = .null
        }
        return .object([
            "index": .integer(trace.index),
            "payload": trace.payload,
            "initial": initial,
            "repair": repair,
            "outcome": outcome,
        ])
    }

    /// The run result: the response, or the error body with the failing
    /// window and its issues.
    public static func adResult(_ outcome: AnalysisOutcome) -> JSONValue {
        switch outcome {
        case .adDetection(let response):
            return .object(["response": response.jsonValue])
        case .failed(let failure):
            return .object([
                "error": AdAnalysisErrorResponse(error: failure.code.rawValue).jsonValue,
                "window": failure.windowIndex.map { .integer($0) } ?? .null,
                "issues": .array(failure.issues.map(JSONValue.string)),
            ])
        case .chaptersSummary:
            return .null
        }
    }

    public static func chaptersParsed(_ parsed: ChaptersParsedAnswer?, result: Result<ChaptersValidatedAnalysis, ChaptersRejection>?) -> JSONValue {
        guard let parsed else { return .null }
        let parse = JSONValue.object([
            "failure": parsed.failure.map(JSONValue.string) ?? .null,
            "warnings": .array(parsed.warnings.map(JSONValue.string)),
            "usage": usage(parsed.usage),
            "has_output": .bool(parsed.output != nil),
        ])
        var resultValue = JSONValue.null
        switch result {
        case .success(let analysis)?:
            resultValue = .object(["ok": .object([
                "chapters": .array(analysis.chapters.map(\.jsonValue)),
                "summary": analysis.summary.jsonValue,
                "warnings": .array(analysis.warnings.map(JSONValue.string)),
            ])])
        case .failure(let rejection)?:
            resultValue = .object(["violations": .array(rejection.violations.map {
                .object(["rule": .string($0.rule), "detail": .string($0.detail)])
            })])
        case nil:
            break
        }
        return .object(["parse": parse, "result": resultValue])
    }

    public static func chaptersResult(_ outcome: AnalysisOutcome) -> JSONValue {
        switch outcome {
        case .chaptersSummary(let response):
            return .object(["response": response.jsonValue])
        case .failed(let failure):
            return .object(["error": .object([
                "status": .integer(failure.status),
                "body": failure.errorJSON(),
            ])])
        case .adDetection:
            return .null
        }
    }
}
