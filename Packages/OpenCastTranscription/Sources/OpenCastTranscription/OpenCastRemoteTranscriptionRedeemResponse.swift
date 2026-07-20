/// Response of `purchases/redeem`: the applied outcome and the account's
/// authoritative balance after it.
public struct OpenCastRemoteTranscriptionRedeemResponse: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var outcome: OpenCastRemoteTranscriptionRedeemOutcome
    public var transactionID: String
    public var creditedSeconds: Int64
    public var balance: OpenCastRemoteTranscriptionBalance

    public init(
        schemaVersion: Int,
        outcome: OpenCastRemoteTranscriptionRedeemOutcome,
        transactionID: String,
        creditedSeconds: Int64,
        balance: OpenCastRemoteTranscriptionBalance
    ) {
        self.schemaVersion = schemaVersion
        self.outcome = outcome
        self.transactionID = transactionID
        self.creditedSeconds = creditedSeconds
        self.balance = balance
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case outcome
        case transactionID = "transaction_id"
        case creditedSeconds = "credited_seconds"
        case balance
    }
}
