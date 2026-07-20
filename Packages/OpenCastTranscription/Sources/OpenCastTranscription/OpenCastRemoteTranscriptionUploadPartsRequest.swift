/// Body of `jobs/{id}/upload/parts`: fresh presigned URLs for exactly the
/// requested part numbers (bounded batches; a 403 on a part is a credential
/// refresh through this route, never a failure).
public struct OpenCastRemoteTranscriptionUploadPartsRequest: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var partNumbers: [Int]
    public var forBackground: Bool?

    public init(
        schemaVersion: Int = OpenCastRemoteTranscriptionSchema.version,
        partNumbers: [Int],
        forBackground: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.partNumbers = partNumbers
        self.forBackground = forBackground
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case partNumbers = "part_numbers"
        case forBackground = "for_background"
    }
}
