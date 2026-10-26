/// One break exactly as the model returned it, before validation.
public struct AdModelSpan: Sendable, Hashable {
    public var kind: String
    public var label: String
    public var startSegmentID: Int64
    public var endSegmentID: Int64
    public var confidence: Double
    public var evidenceQuote: String
    public var startQuote: String
    public var endQuote: String

    public init(
        kind: String,
        label: String,
        startSegmentID: Int64,
        endSegmentID: Int64,
        confidence: Double,
        evidenceQuote: String,
        startQuote: String,
        endQuote: String
    ) {
        self.kind = kind
        self.label = label
        self.startSegmentID = startSegmentID
        self.endSegmentID = endSegmentID
        self.confidence = confidence
        self.evidenceQuote = evidenceQuote
        self.startQuote = startQuote
        self.endQuote = endQuote
    }

    static let shape = StrictDecoding.Shape(
        fields: [
            "kind", "label", "start_segment_id", "end_segment_id", "confidence",
            "evidence_quote", "start_quote", "end_quote",
        ],
        denyUnknownFields: true
    )

    init(json: JSONValue) throws(StrictDecodingError) {
        let fields = try StrictDecoding.fields(json, Self.shape)
        kind = try StrictDecoding.string(fields["kind"]!)
        label = try StrictDecoding.string(fields["label"]!)
        startSegmentID = try StrictDecoding.int64(fields["start_segment_id"]!)
        endSegmentID = try StrictDecoding.int64(fields["end_segment_id"]!)
        confidence = try StrictDecoding.double(fields["confidence"]!)
        evidenceQuote = try StrictDecoding.string(fields["evidence_quote"]!)
        startQuote = try StrictDecoding.string(fields["start_quote"]!)
        endQuote = try StrictDecoding.string(fields["end_quote"]!)
    }

    /// Fields in declaration order, as a typed serializer writes them.
    var jsonValue: JSONValue {
        .object([
            "kind": .string(kind),
            "label": .string(label),
            "start_segment_id": .number(.integer(startSegmentID)),
            "end_segment_id": .number(.integer(endSegmentID)),
            "confidence": .double(confidence),
            "evidence_quote": .string(evidenceQuote),
            "start_quote": .string(startQuote),
            "end_quote": .string(endQuote),
        ])
    }
}

/// The model's whole answer for one window: every break it found. Unknown
/// or missing fields, wrong types and repeated fields reject the answer.
public struct AdModelOutput: Sendable, Hashable {
    public var spans: [AdModelSpan]

    public init(spans: [AdModelSpan]) {
        self.spans = spans
    }

    public init(json: JSONValue) throws(StrictDecodingError) {
        let fields = try StrictDecoding.fields(json, .init(fields: ["spans"], denyUnknownFields: true))
        var spans: [AdModelSpan] = []
        for element in try StrictDecoding.array(fields["spans"]!) {
            spans.append(try AdModelSpan(json: element))
        }
        self.spans = spans
    }

    /// Parses answer text with the service's acceptance rules.
    public init(text: String) throws {
        try self.init(json: try JSONParser.parse(text))
    }

    var jsonValue: JSONValue {
        .object(["spans": .array(spans.map(\.jsonValue))])
    }
}
