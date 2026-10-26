/// A JSON number as the Rust analysis services classify it while parsing:
/// non-negative integers that fit 64 bits stay unsigned, negative integers
/// that fit stay signed, and everything else is a binary64 value.
public enum JSONNumber: Sendable, Hashable {
    case unsigned(UInt64)
    case negative(Int64)
    case double(Double)

    /// An integer in the unsigned / negative classification.
    public static func integer(_ value: Int64) -> JSONNumber {
        value >= 0 ? .unsigned(UInt64(value)) : .negative(value)
    }

    /// The value as a binary64, the way a floating-point field reads it.
    public var doubleValue: Double {
        switch self {
        case .unsigned(let value): Double(value)
        case .negative(let value): Double(value)
        case .double(let value): value
        }
    }
}

/// One object member. Members keep their source order and duplicates so a
/// strict decoder can reject a repeated field instead of silently picking one.
public struct JSONMember: Sendable, Hashable {
    public var key: String
    public var value: JSONValue
    /// The key's escapes held an unpaired UTF-16 surrogate (`key` is then a
    /// placeholder). Legal inside an ignored value; a typed struct read
    /// rejects it, as the services' reader does.
    public var keyHasUnpairedSurrogate = false

    public init(_ key: String, _ value: JSONValue) {
        self.key = key
        self.value = value
    }
}

/// A parsed or constructed JSON document.
public indirect enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(JSONNumber)
    case string(String)
    /// A string whose escapes held an unpaired UTF-16 surrogate. It is legal
    /// JSON text but cannot become a Swift or Rust string; a decoder that
    /// needs its text treats it as a type error, while an ignored field
    /// tolerates it.
    case unpairedSurrogateString
    /// A well-formed number literal outside binary64 range (such as `1e400`).
    /// Any numeric field rejects it; an ignored field tolerates it.
    case unrepresentableNumber
    /// An array or object at the nesting level where the Rust reader's
    /// typed path stops (``JSONParser/maximumNesting``). It is legal JSON,
    /// checked but not kept; every typed read rejects it, while an ignored
    /// field tolerates it at any depth.
    case tooDeepContainer
    case array([JSONValue])
    case object([JSONMember])

    public static func integer(_ value: Int) -> JSONValue {
        .number(.integer(Int64(value)))
    }

    public static func double(_ value: Double) -> JSONValue {
        .number(.double(value))
    }

    /// An object built from members in the given order.
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

    /// The same document with every object's keys in ascending UTF-8 byte
    /// order, the order a Rust `serde_json::Value` map serializes in.
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
