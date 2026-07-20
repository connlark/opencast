/// Body of `jobs/{id}/source`: the device's exact identity of its completed
/// local download.
public struct OpenCastRemoteTranscriptionSourceReportRequest: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var sourceIdentity: OpenCastRemoteTranscriptionSourceIdentity

    public init(
        schemaVersion: Int = OpenCastRemoteTranscriptionSchema.version,
        sourceIdentity: OpenCastRemoteTranscriptionSourceIdentity
    ) {
        self.schemaVersion = schemaVersion
        self.sourceIdentity = sourceIdentity
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sourceIdentity = "source_identity"
    }
}
