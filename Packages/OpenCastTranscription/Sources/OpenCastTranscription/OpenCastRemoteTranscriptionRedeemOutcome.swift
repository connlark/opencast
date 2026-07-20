/// Server acknowledgement for a redeemed transaction. Every case is safe to
/// finish against: `credited` and `alreadyCredited` mean the seconds are
/// durably on the account; `refunded` means Apple revoked the purchase and
/// no credit is owed. Unknown future outcomes are preserved and must NOT be
/// finished (fail closed).
public enum OpenCastRemoteTranscriptionRedeemOutcome: Sendable, Equatable, Hashable {
    case credited
    case alreadyCredited
    case refunded
    case unknown(String)

    public init(wireValue: String) {
        switch wireValue {
        case "credited": self = .credited
        case "already_credited": self = .alreadyCredited
        case "refunded": self = .refunded
        default: self = .unknown(wireValue)
        }
    }

    public var wireValue: String {
        switch self {
        case .credited: "credited"
        case .alreadyCredited: "already_credited"
        case .refunded: "refunded"
        case let .unknown(value): value
        }
    }

    /// Whether the app may call `transaction.finish()` for this outcome.
    public var isFinishable: Bool {
        switch self {
        case .credited, .alreadyCredited, .refunded: true
        case .unknown: false
        }
    }
}

extension OpenCastRemoteTranscriptionRedeemOutcome: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(wireValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}
