public enum JSONNumber: Sendable, Hashable {
    case unsigned(UInt64)
    case negative(Int64)
    case double(Double)

    public static func integer(_ value: Int64) -> JSONNumber {
        value >= 0 ? .unsigned(UInt64(value)) : .negative(value)
    }

    public var doubleValue: Double {
        switch self {
        case .unsigned(let value): Double(value)
        case .negative(let value): Double(value)
        case .double(let value): value
        }
    }
}

/// Objects keep members in source order with duplicates, so a strict decoder can reject a repeat.
public struct JSONMember: Sendable, Hashable {
    public var key: String
    public var value: JSONValue
    /// When set, `key` is a placeholder; a typed struct read rejects the member.
    public var keyHasUnpairedSurrogate = false

    public init(_ key: String, _ value: JSONValue) {
        self.key = key
        self.value = value
    }
}

public indirect enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(JSONNumber)
    case string(String)
    /// Legal JSON with no Swift string form: a typed read rejects it, an ignored field accepts it.
    case unpairedSurrogateString
    /// Beyond binary64 range, like `1e400`; a numeric field rejects it, an ignored one accepts it.
    case unrepresentableNumber
    /// Checked but not kept, at ``JSONParser/maximumNesting``; a typed read rejects it.
    case tooDeepContainer
    case array([JSONValue])
    case object([JSONMember])

    public static func integer(_ value: Int) -> JSONValue {
        .number(.integer(Int64(value)))
    }

    public static func double(_ value: Double) -> JSONValue {
        .number(.double(value))
    }

    public static func object(_ members: KeyValuePairs<String, JSONValue>) -> JSONValue {
        .object(members.map { JSONMember($0.key, $0.value) })
    }

    /// The first member with `key`, for lenient reads of trusted documents.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    public var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { value } else { nil }
    }

    public var objectMembers: [JSONMember]? {
        if case .object(let value) = self { value } else { nil }
    }

    /// UTF-8 byte order, as a Rust `serde_json::Value` map serializes.
    public func sortedKeys() -> JSONValue {
        switch self {
        case .array(let values):
            return .array(values.map { $0.sortedKeys() })
        case .object(let members):
            return .object(
                members
                    .map { JSONMember($0.key, $0.value.sortedKeys()) }
                    .sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
            )
        case .null, .bool, .number, .string, .unpairedSurrogateString, .unrepresentableNumber, .tooDeepContainer:
            return self
        }
    }
}
