/// One uploaded part's proof: its 1-based number and the ETag the presigned
/// PUT returned.
public struct OpenCastRemoteTranscriptionUploadCompletedPart: Codable, Sendable, Equatable {
    public var partNumber: Int
    public var etag: String

    public init(partNumber: Int, etag: String) {
        self.partNumber = partNumber
        self.etag = etag
    }

    enum CodingKeys: String, CodingKey {
        case partNumber = "part_number"
        case etag
    }
}

/// Body of `jobs/{id}/upload/complete`: the server completes the multipart
/// upload idempotently, then re-verifies the object's identity against the
/// authenticated device report before any reservation.
public struct OpenCastRemoteTranscriptionUploadCompleteRequest: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var parts: [OpenCastRemoteTranscriptionUploadCompletedPart]

    public init(
        schemaVersion: Int = OpenCastRemoteTranscriptionSchema.version,
        parts: [OpenCastRemoteTranscriptionUploadCompletedPart]
    ) {
        self.schemaVersion = schemaVersion
        self.parts = parts
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case parts
    }
}
