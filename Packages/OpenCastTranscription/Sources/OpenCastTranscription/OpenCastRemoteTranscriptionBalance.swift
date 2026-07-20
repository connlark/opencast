/// Account balance in integer audio seconds. The server ledger is the only
/// authority; the app never persists this beyond display state.
public struct OpenCastRemoteTranscriptionBalance: Codable, Sendable, Equatable {
    public var availableSeconds: Int64
    public var reservedSeconds: Int64
    public var debtSeconds: Int64

    public init(availableSeconds: Int64, reservedSeconds: Int64, debtSeconds: Int64 = 0) {
        self.availableSeconds = availableSeconds
        self.reservedSeconds = reservedSeconds
        self.debtSeconds = debtSeconds
    }

    enum CodingKeys: String, CodingKey {
        case availableSeconds = "available_seconds"
        case reservedSeconds = "reserved_seconds"
        case debtSeconds = "debt_seconds"
    }
}
