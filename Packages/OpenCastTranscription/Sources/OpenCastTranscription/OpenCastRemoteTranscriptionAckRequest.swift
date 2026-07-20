/// Body of `jobs/{id}/ack`, sent only after the transcript document is
/// durably written locally. The normalized hash echoes what was imported so
/// the server can record integrity evidence before deleting the result.
public struct OpenCastRemoteTranscriptionAckRequest: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var normalizedTranscriptSHA256: String?

    public init(
        schemaVersion: Int = OpenCastRemoteTranscriptionSchema.version,
        normalizedTranscriptSHA256: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.normalizedTranscriptSHA256 = normalizedTranscriptSHA256
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case normalizedTranscriptSHA256 = "normalized_transcript_sha256"
    }
}
