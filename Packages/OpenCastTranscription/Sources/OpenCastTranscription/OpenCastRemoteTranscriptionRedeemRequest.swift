public struct OpenCastRemoteTranscriptionRedeemRequest: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var transactionJWS: String

    public init(
        schemaVersion: Int = OpenCastRemoteTranscriptionSchema.version,
        transactionJWS: String
    ) {
        self.schemaVersion = schemaVersion
        self.transactionJWS = transactionJWS
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case transactionJWS = "transaction_jws"
    }
}
