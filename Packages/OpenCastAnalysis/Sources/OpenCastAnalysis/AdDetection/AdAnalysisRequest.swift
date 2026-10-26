/// One transcript segment as the analysis services receive it.
public struct AnalysisSegment: Sendable, Hashable {
    public var id: Int64
    public var start: Double
    public var end: Double
    public var text: String

    public init(id: Int64, start: Double, end: Double, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
    }

    init(json: JSONValue) throws(StrictDecodingError) {
        let fields = try StrictDecoding.fields(json, .init(fields: ["id", "start", "end", "text"]))
        id = try StrictDecoding.int64(fields["id"]!)
        start = try StrictDecoding.double(fields["start"]!)
        end = try StrictDecoding.double(fields["end"]!)
        text = try StrictDecoding.string(fields["text"]!)
    }

    var jsonValue: JSONValue {
        .object([
            "id": .number(.integer(id)),
            "start": .double(start),
            "end": .double(end),
            "text": .string(text),
        ])
    }
}

/// Transcript metadata of an ad-detection request.
public struct AdAnalysisTranscript: Sendable, Hashable {
    public var languageCode: String
    public var audioDuration: Double
    /// The feed's declared runtime. When the served file is longer, the
    /// excess is counted as inserted advertising in the episode ad budget.
    public var declaredDuration: Double?
    public var modelIdentifier: String?
    public var modelVersion: String?
    public var modelTreeSHA256: String?
    public var fingerprint: String
    public var updatedAt: String
    public var state: String
    public var segmentCount: Int

    public init(
        languageCode: String,
        audioDuration: Double,
        declaredDuration: Double? = nil,
        modelIdentifier: String? = nil,
        modelVersion: String? = nil,
        modelTreeSHA256: String? = nil,
        fingerprint: String,
        updatedAt: String,
        state: String = "completed",
        segmentCount: Int
    ) {
        self.languageCode = languageCode
        self.audioDuration = audioDuration
        self.declaredDuration = declaredDuration
        self.modelIdentifier = modelIdentifier
        self.modelVersion = modelVersion
        self.modelTreeSHA256 = modelTreeSHA256
        self.fingerprint = fingerprint
        self.updatedAt = updatedAt
        self.state = state
        self.segmentCount = segmentCount
    }

    static let shape = StrictDecoding.Shape(
        fields: [
            "language_code", "audio_duration", "declared_duration", "model_identifier",
            "model_version", "model_tree_sha256", "fingerprint", "updated_at", "state",
            "segment_count",
        ],
        defaulted: ["declared_duration", "model_identifier", "model_version", "model_tree_sha256"]
    )

    init(json: JSONValue) throws(StrictDecodingError) {
        let fields = try StrictDecoding.fields(json, Self.shape)
        languageCode = try StrictDecoding.string(fields["language_code"]!)
        audioDuration = try StrictDecoding.double(fields["audio_duration"]!)
        declaredDuration = try StrictDecoding.optional(fields["declared_duration"], StrictDecoding.double)
        modelIdentifier = try StrictDecoding.optional(fields["model_identifier"], StrictDecoding.string)
        modelVersion = try StrictDecoding.optional(fields["model_version"], StrictDecoding.string)
        modelTreeSHA256 = try StrictDecoding.optional(fields["model_tree_sha256"], StrictDecoding.string)
        fingerprint = try StrictDecoding.string(fields["fingerprint"]!)
        updatedAt = try StrictDecoding.string(fields["updated_at"]!)
        state = try StrictDecoding.string(fields["state"]!)
        segmentCount = try StrictDecoding.count(fields["segment_count"]!)
    }
}

/// An ad-detection request: the episode's identity and its whole transcript.
public struct AdAnalysisRequest: Sendable, Hashable {
    public var schemaVersion: UInt16
    public var requestID: String
    public var episodeID: String
    public var podcastID: String
    public var episodeTitle: String?
    public var podcastTitle: String?
    public var transcript: AdAnalysisTranscript
    public var segments: [AnalysisSegment]

    public init(
        schemaVersion: UInt16 = 1,
        requestID: String,
        episodeID: String,
        podcastID: String,
        episodeTitle: String?,
        podcastTitle: String?,
        transcript: AdAnalysisTranscript,
        segments: [AnalysisSegment]
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.episodeID = episodeID
        self.podcastID = podcastID
        self.episodeTitle = episodeTitle
        self.podcastTitle = podcastTitle
        self.transcript = transcript
        self.segments = segments
    }

    static let shape = StrictDecoding.Shape(
        fields: [
            "schema_version", "async_supported", "retry_failed", "job_handle_version",
            "request_id", "episode_id", "podcast_id", "episode_title", "podcast_title",
            "transcript", "segments",
        ],
        defaulted: [
            "async_supported", "retry_failed", "job_handle_version", "episode_title", "podcast_title",
        ]
    )

    /// Reads the request JSON the ad-analysis service accepts.
    public init(json: JSONValue) throws(StrictDecodingError) {
        let fields = try StrictDecoding.fields(json, Self.shape)
        schemaVersion = try StrictDecoding.unsigned(fields["schema_version"]!, as: UInt16.self)
        if let value = fields["async_supported"] { _ = try StrictDecoding.bool(value) }
        if let value = fields["retry_failed"] { _ = try StrictDecoding.bool(value) }
        _ = try StrictDecoding.optional(fields["job_handle_version"]) { value throws(StrictDecodingError) in
            try StrictDecoding.unsigned(value, as: UInt8.self)
        }
        requestID = try StrictDecoding.string(fields["request_id"]!)
        episodeID = try StrictDecoding.string(fields["episode_id"]!)
        podcastID = try StrictDecoding.string(fields["podcast_id"]!)
        episodeTitle = try StrictDecoding.optional(fields["episode_title"], StrictDecoding.string)
        podcastTitle = try StrictDecoding.optional(fields["podcast_title"], StrictDecoding.string)
        transcript = try AdAnalysisTranscript(json: fields["transcript"]!)
        var segments: [AnalysisSegment] = []
        for element in try StrictDecoding.array(fields["segments"]!) {
            segments.append(try AnalysisSegment(json: element))
        }
        self.segments = segments
    }

    /// The same request restricted to `range` of its segments, as one
    /// analysis window sees it.
    func window(_ range: Range<Int>) -> AdAnalysisRequest {
        var window = self
        window.segments = Array(segments[range])
        window.transcript.segmentCount = window.segments.count
        return window
    }
}
