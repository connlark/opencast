/// Transcript metadata of a Chapters & Summary request.
public struct TranscriptAnalysisTranscript: Sendable, Hashable {
    public var languageCode: String
    public var audioDuration: Double
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
            "language_code", "audio_duration", "model_identifier", "model_version",
            "model_tree_sha256", "fingerprint", "updated_at", "state", "segment_count",
        ],
        defaulted: ["model_identifier", "model_version", "model_tree_sha256"]
    )

    init(json: JSONValue) throws(StrictDecodingError) {
        let fields = try StrictDecoding.fields(json, Self.shape)
        languageCode = try StrictDecoding.string(fields["language_code"]!)
        audioDuration = try StrictDecoding.double(fields["audio_duration"]!)
        modelIdentifier = try StrictDecoding.optional(fields["model_identifier"], StrictDecoding.string)
        modelVersion = try StrictDecoding.optional(fields["model_version"], StrictDecoding.string)
        modelTreeSHA256 = try StrictDecoding.optional(fields["model_tree_sha256"], StrictDecoding.string)
        fingerprint = try StrictDecoding.string(fields["fingerprint"]!)
        updatedAt = try StrictDecoding.string(fields["updated_at"]!)
        state = try StrictDecoding.string(fields["state"]!)
        segmentCount = try StrictDecoding.count(fields["segment_count"]!)
    }

    var jsonValue: JSONValue {
        func optional(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
        return .object([
            "language_code": .string(languageCode),
            "audio_duration": .double(audioDuration),
            "model_identifier": optional(modelIdentifier),
            "model_version": optional(modelVersion),
            "model_tree_sha256": optional(modelTreeSHA256),
            "fingerprint": .string(fingerprint),
            "updated_at": .string(updatedAt),
            "state": .string(state),
            "segment_count": .integer(segmentCount),
        ])
    }
}

/// A Chapters & Summary request: the episode's identity, its real titles
/// and its whole transcript.
public struct TranscriptAnalysisRequest: Sendable, Hashable {
    public var schemaVersion: UInt16
    public var asyncSupported: Bool
    public var requestID: String
    public var episodeID: String
    public var podcastID: String
    public var episodeTitle: String?
    public var podcastTitle: String?
    public var transcript: TranscriptAnalysisTranscript
    public var segments: [AnalysisSegment]

    public init(
        schemaVersion: UInt16 = 1,
        asyncSupported: Bool = false,
        requestID: String,
        episodeID: String,
        podcastID: String,
        episodeTitle: String?,
        podcastTitle: String?,
        transcript: TranscriptAnalysisTranscript,
        segments: [AnalysisSegment]
    ) {
        self.schemaVersion = schemaVersion
        self.asyncSupported = asyncSupported
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
            "schema_version", "async_supported", "request_id", "episode_id", "podcast_id",
            "episode_title", "podcast_title", "transcript", "segments",
        ],
        defaulted: ["async_supported", "episode_title", "podcast_title"]
    )

    /// Reads the request JSON the Chapters & Summary service accepts.
    public init(json: JSONValue) throws(StrictDecodingError) {
        let fields = try StrictDecoding.fields(json, Self.shape)
        schemaVersion = try StrictDecoding.unsigned(fields["schema_version"]!, as: UInt16.self)
        asyncSupported = try fields["async_supported"].map(StrictDecoding.bool) ?? false
        requestID = try StrictDecoding.string(fields["request_id"]!)
        episodeID = try StrictDecoding.string(fields["episode_id"]!)
        podcastID = try StrictDecoding.string(fields["podcast_id"]!)
        episodeTitle = try StrictDecoding.optional(fields["episode_title"], StrictDecoding.string)
        podcastTitle = try StrictDecoding.optional(fields["podcast_title"], StrictDecoding.string)
        transcript = try TranscriptAnalysisTranscript(json: fields["transcript"]!)
        var segments: [AnalysisSegment] = []
        for element in try StrictDecoding.array(fields["segments"]!) {
            segments.append(try AnalysisSegment(json: element))
        }
        self.segments = segments
    }

    /// Field order and null handling as the service serializes the type.
    public var jsonValue: JSONValue {
        .object([
            "schema_version": .number(.unsigned(UInt64(schemaVersion))),
            "async_supported": .bool(asyncSupported),
            "request_id": .string(requestID),
            "episode_id": .string(episodeID),
            "podcast_id": .string(podcastID),
            "episode_title": episodeTitle.map(JSONValue.string) ?? .null,
            "podcast_title": podcastTitle.map(JSONValue.string) ?? .null,
            "transcript": transcript.jsonValue,
            "segments": .array(segments.map(\.jsonValue)),
        ])
    }
}
