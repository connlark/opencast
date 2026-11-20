public struct OpenCastRemoteTranscriptionJobResponse: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var job: OpenCastRemoteTranscriptionJobStatus
    public var balance: OpenCastRemoteTranscriptionBalance?

    public init(
        schemaVersion: Int,
        job: OpenCastRemoteTranscriptionJobStatus,
        balance: OpenCastRemoteTranscriptionBalance? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.job = job
        self.balance = balance
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case job
        case balance
    }
}
