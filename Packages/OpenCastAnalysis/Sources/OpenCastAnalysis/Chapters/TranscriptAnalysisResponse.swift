/// A validated chapter, with times taken from the transcript.
public struct TranscriptAnalysisChapter: Sendable, Hashable {
    public var title: String
    public var startSegmentID: Int64
    public var endSegmentID: Int64
    public var startTime: Double
    public var endTime: Double
    public var confidence: Double

    var jsonValue: JSONValue {
        .object([
            "title": .string(title),
            "start_segment_id": .number(.integer(startSegmentID)),
            "end_segment_id": .number(.integer(endSegmentID)),
            "start_time": .double(startTime),
            "end_time": .double(endTime),
            "confidence": .double(confidence),
        ])
    }
}

public struct TranscriptAnalysisClaim: Sendable, Hashable {
    public var text: String
    public var evidenceSegmentID: Int64

    var jsonValue: JSONValue {
        .object(["text": .string(text), "evidence_segment_id": .number(.integer(evidenceSegmentID))])
    }
}

public struct TranscriptAnalysisSummary: Sendable, Hashable {
    public var summary: String
    public var oneLineDescription: String
    public var claims: [TranscriptAnalysisClaim]

    var jsonValue: JSONValue {
        .object([
            "summary": .string(summary),
            "one_line_description": .string(oneLineDescription),
            "claims": .array(claims.map(\.jsonValue)),
        ])
    }
}

/// A completed Chapters & Summary analysis: the JSON object the service
/// returns to the app.
public struct TranscriptAnalysisResponse: Sendable, Hashable {
    public var schemaVersion: UInt16
    public var requestID: String
    public var model: String
    public var policy: String
    public var chapters: [TranscriptAnalysisChapter]
    public var summary: TranscriptAnalysisSummary?
    public var warnings: [String]
    public var usage: AnalysisUsage?

    public var jsonValue: JSONValue {
        var members: [JSONMember] = [
            JSONMember("schema_version", .number(.unsigned(UInt64(schemaVersion)))),
            JSONMember("request_id", .string(requestID)),
            JSONMember("model", .string(model)),
            JSONMember("policy", .string(policy)),
            JSONMember("chapters", .array(chapters.map(\.jsonValue))),
            JSONMember("summary", summary?.jsonValue ?? .null),
            JSONMember("warnings", .array(warnings.map(JSONValue.string))),
        ]
        if let usage { members.append(JSONMember("usage", usage.jsonValue)) }
        return .object(members)
    }

    /// The response body text, byte for byte as the service writes it.
    public var jsonText: String { JSONWriter.string(jsonValue) }
}

/// The error body the Chapters & Summary service returns: a code and, for
/// rejected answers, the comma-joined rule codes.
public struct TranscriptAnalysisErrorResponse: Sendable, Hashable {
    /// The HTTP status the service answers with.
    public var status: Int
    public var error: String
    public var detail: String?

    public var jsonValue: JSONValue {
        var members = [JSONMember("error", .string(error))]
        if let detail { members.append(JSONMember("detail", .string(detail))) }
        return .object(members)
    }
}
