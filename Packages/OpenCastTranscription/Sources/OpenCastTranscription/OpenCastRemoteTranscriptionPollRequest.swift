public struct OpenCastRemoteTranscriptionPollRequest: Codable, Sendable, Equatable {
    public var schemaVersion: Int

    public init(schemaVersion: Int = OpenCastRemoteTranscriptionSchema.version) {
        self.schemaVersion = schemaVersion
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
    }
}
