/// A completed remote transcription result as served by the job `result`
/// route. The app validates this against the local file identity and builds
/// its own persisted document from it; the wire type is never persisted
/// directly.
public struct OpenCastRemoteTranscriptionResult: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var sourceIdentity: OpenCastRemoteTranscriptionSourceIdentity
    public var languageCode: String
    public var durationSeconds: Double
    public var text: String
    public var segments: [OpenCastRemoteTranscriptSegment]
    public var provenance: OpenCastRemoteTranscriptionModelProvenance
    public var warnings: [String]

    public init(
        schemaVersion: Int,
        sourceIdentity: OpenCastRemoteTranscriptionSourceIdentity,
        languageCode: String,
        durationSeconds: Double,
        text: String,
        segments: [OpenCastRemoteTranscriptSegment],
        provenance: OpenCastRemoteTranscriptionModelProvenance,
        warnings: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.sourceIdentity = sourceIdentity
        self.languageCode = languageCode
        self.durationSeconds = durationSeconds
        self.text = text
        self.segments = segments
        self.provenance = provenance
        self.warnings = warnings
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sourceIdentity = "source_identity"
        case languageCode = "language_code"
        case durationSeconds = "duration_seconds"
        case text
        case segments
        case provenance
        case warnings
    }
}
