/// Body of `jobs/{id}/poll`, `jobs/{id}/result`, and `jobs/{id}/cancel`:
/// just the schema version — the job ID is bound into the signed path.
public struct OpenCastRemoteTranscriptionPollRequest: Codable, Sendable, Equatable {
    public var schemaVersion: Int

    public init(schemaVersion: Int = OpenCastRemoteTranscriptionSchema.version) {
        self.schemaVersion = schemaVersion
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
    }
}
