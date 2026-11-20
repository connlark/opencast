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
