/// A bearer credential: never log the URL. `expiresAt` is epoch seconds; after it the URL
/// returns 403 and is refreshed through `upload/parts`.
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

/// Every non-final part is exactly `partSizeBytes`; the final part is the remainder.
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
