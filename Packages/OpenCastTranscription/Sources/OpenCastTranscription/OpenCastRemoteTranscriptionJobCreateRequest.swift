/// Body of `jobs` (create). Repeated submissions with the same
/// `clientRequestID` attach to the same job instead of creating a second paid
/// run. `episodeID` is the app's opaque episode hash, kept server-side only
/// for relaunch correlation; the enclosure URL is stored encrypted and
/// cleared once staging completes.
public struct OpenCastRemoteTranscriptionJobCreateRequest: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var clientRequestID: String
    public var episodeID: String
    public var enclosureURL: String
    public var declaredDurationSeconds: Double?
    public var languageCode: String?
    public var sourceIdentity: OpenCastRemoteTranscriptionSourceIdentity?
    /// Chains server-side ad detection after stitching; requires `podcastID`.
    public var adAnalysisRequested: Bool?
    public var podcastID: String?
    /// Prompt context only; never required, never echoed back.
    public var episodeTitle: String?
    public var podcastTitle: String?

    public init(
        schemaVersion: Int = OpenCastRemoteTranscriptionSchema.version,
        clientRequestID: String,
        episodeID: String,
        enclosureURL: String,
        declaredDurationSeconds: Double? = nil,
        languageCode: String? = nil,
        sourceIdentity: OpenCastRemoteTranscriptionSourceIdentity? = nil,
        adAnalysisRequested: Bool? = nil,
        podcastID: String? = nil,
        episodeTitle: String? = nil,
        podcastTitle: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.clientRequestID = clientRequestID
        self.episodeID = episodeID
        self.enclosureURL = enclosureURL
        self.declaredDurationSeconds = declaredDurationSeconds
        self.languageCode = languageCode
        self.sourceIdentity = sourceIdentity
        self.adAnalysisRequested = adAnalysisRequested
        self.podcastID = podcastID
        self.episodeTitle = episodeTitle
        self.podcastTitle = podcastTitle
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case clientRequestID = "client_request_id"
        case episodeID = "episode_id"
        case enclosureURL = "enclosure_url"
        case declaredDurationSeconds = "declared_duration_seconds"
        case languageCode = "language_code"
        case sourceIdentity = "source_identity"
        case adAnalysisRequested = "ad_analysis_requested"
        case podcastID = "podcast_id"
        case episodeTitle = "episode_title"
        case podcastTitle = "podcast_title"
    }
}
