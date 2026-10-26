import Foundation

/// A JSON value carried verbatim by the policy bundle, such as a feature's
/// response schema. Numbers are `Double`; the schemas the bundle carries hold
/// none, so nothing round-trips through a lossy conversion.
public enum AnalysisPolicyJSON: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AnalysisPolicyJSON])
    case object([String: AnalysisPolicyJSON])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AnalysisPolicyJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: AnalysisPolicyJSON].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    /// Compact JSON with sorted keys, the form the workers' `serde_json`
    /// writes for the same value.
    public func sortedKeysData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
