/// Body of `jobs/{id}/upload/start`: opens (or idempotently resumes) the
/// exact-device multipart upload and returns the first bounded batch of
/// presigned part URLs. `forBackground` requests the longer bounded URL
/// expiry for background-enqueued parts.
public struct OpenCastRemoteTranscriptionUploadStartRequest: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var forBackground: Bool?

    public init(
        schemaVersion: Int = OpenCastRemoteTranscriptionSchema.version,
        forBackground: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.forBackground = forBackground
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case forBackground = "for_background"
    }
}
