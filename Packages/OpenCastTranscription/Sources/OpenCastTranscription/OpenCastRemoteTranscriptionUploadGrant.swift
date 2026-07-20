/// One presigned `UploadPart` PUT URL. Treat as a bearer credential: never
/// log it; `expiresAt` is epoch seconds, after which the URL 403s and must be
/// refreshed through `upload/parts`.
public struct OpenCastRemoteTranscriptionUploadPartGrant: Codable, Sendable, Equatable {
    public var partNumber: Int
    public var url: String
    public var expiresAt: Int64

    public init(partNumber: Int, url: String, expiresAt: Int64) {
        self.partNumber = partNumber
        self.url = url
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case partNumber = "part_number"
        case url
        case expiresAt = "expires_at"
    }
}

/// Response of `upload/start` and `upload/parts`: the upload's identity and
/// uniform-part geometry (every non-final part is exactly `partSizeBytes`;
/// the final part is the remainder) plus a bounded batch of part URLs.
public struct OpenCastRemoteTranscriptionUploadGrantResponse: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var uploadKeyID: String
    public var partSizeBytes: Int64
    public var partCount: Int
    public var parts: [OpenCastRemoteTranscriptionUploadPartGrant]

    public init(
        schemaVersion: Int,
        uploadKeyID: String,
        partSizeBytes: Int64,
        partCount: Int,
        parts: [OpenCastRemoteTranscriptionUploadPartGrant]
    ) {
        self.schemaVersion = schemaVersion
        self.uploadKeyID = uploadKeyID
        self.partSizeBytes = partSizeBytes
        self.partCount = partCount
        self.parts = parts
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case uploadKeyID = "upload_key_id"
        case partSizeBytes = "part_size_bytes"
        case partCount = "part_count"
        case parts
    }
}
