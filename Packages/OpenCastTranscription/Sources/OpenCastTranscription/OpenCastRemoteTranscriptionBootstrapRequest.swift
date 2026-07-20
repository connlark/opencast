/// Body of `account/bootstrap`. The app-transaction JWS field exists from
/// day one so the wire shape is stable; the development lane ignores it and
/// keys the account to the registered App Attest install.
public struct OpenCastRemoteTranscriptionBootstrapRequest: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var appTransactionJWS: String?

    public init(
        schemaVersion: Int = OpenCastRemoteTranscriptionSchema.version,
        appTransactionJWS: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.appTransactionJWS = appTransactionJWS
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case appTransactionJWS = "app_transaction_jws"
    }
}
