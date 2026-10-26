/// A typed read of a parsed document failed. The pipeline never needs the
/// reason, only that the document does not have the expected shape.
public struct StrictDecodingError: Error, Sendable, Equatable {
    public let reason: String

    init(_ reason: String) {
        self.reason = reason
    }
}

/// Field-level reads with the acceptance rules of a Rust `serde` derive:
/// integers must be integral and in range, floats accept any number, strings
/// reject unpaired surrogates, and a struct reads from an object (by name)
/// or from an array (by position).
enum StrictDecoding {
    struct Shape {
        /// Field names in declaration order.
        var fields: [String]
        /// Fields with a default value: absent is allowed in both forms.
        var defaulted: Set<String> = []
        /// `Option` fields without a default: absent is allowed only when
        /// reading from an object.
        var optional: Set<String> = []
        /// Reject unknown names when reading from an object.
        var denyUnknownFields = false
    }

    /// The present fields of a struct, by name. Absent fields are omitted;
    /// callers apply the default or `nil`.
    static func fields(_ value: JSONValue, _ shape: Shape) throws(StrictDecodingError) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        switch value {
        case .object(let members):
            if members.contains(where: \.keyHasUnpairedSurrogate) {
                throw StrictDecodingError("unreadable field name")
            }
            for member in members {
                // Field names match by bytes, as serde's identifiers do.
                if let name = shape.fields.first(where: { RustText.same(member.key, $0) }) {
                    guard result[name] == nil else {
                        throw StrictDecodingError("duplicate field \(name)")
                    }
                    result[name] = member.value
                } else if shape.denyUnknownFields {
                    throw StrictDecodingError("unknown field \(member.key)")
                }
            }
            for name in shape.fields where result[name] == nil {
                guard shape.defaulted.contains(name) || shape.optional.contains(name) else {
                    throw StrictDecodingError("missing field \(name)")
                }
            }
        case .array(let elements):
            guard elements.count <= shape.fields.count else {
                throw StrictDecodingError("trailing elements")
            }
            for (index, name) in shape.fields.enumerated() {
                if index < elements.count {
                    result[name] = elements[index]
                } else if !shape.defaulted.contains(name) {
                    throw StrictDecodingError("invalid length")
                }
            }
        default:
            throw StrictDecodingError("expected struct")
        }
        return result
    }

    static func string(_ value: JSONValue) throws(StrictDecodingError) -> String {
        guard case .string(let text) = value else { throw StrictDecodingError("expected string") }
        return text
    }

    static func int64(_ value: JSONValue) throws(StrictDecodingError) -> Int64 {
        switch value {
        case .number(.unsigned(let number)):
            guard number <= UInt64(Int64.max) else { throw StrictDecodingError("integer out of range") }
            return Int64(number)
        case .number(.negative(let number)):
            return number
        default:
            throw StrictDecodingError("expected integer")
        }
    }

    static func uint64(_ value: JSONValue) throws(StrictDecodingError) -> UInt64 {
        guard case .number(.unsigned(let number)) = value else {
            throw StrictDecodingError("expected unsigned integer")
        }
        return number
    }

    static func unsigned<T: FixedWidthInteger & UnsignedInteger>(_ value: JSONValue, as type: T.Type) throws(StrictDecodingError) -> T {
        let number = try uint64(value)
        guard let narrowed = T(exactly: number) else { throw StrictDecodingError("integer out of range") }
        return narrowed
    }

    /// A Rust `usize` read into `Int`.
    static func count(_ value: JSONValue) throws(StrictDecodingError) -> Int {
        let number = try uint64(value)
        guard let count = Int(exactly: number) else { throw StrictDecodingError("integer out of range") }
        return count
    }

    static func double(_ value: JSONValue) throws(StrictDecodingError) -> Double {
        guard case .number(let number) = value else { throw StrictDecodingError("expected number") }
        return number.doubleValue
    }

    static func bool(_ value: JSONValue) throws(StrictDecodingError) -> Bool {
        guard case .bool(let flag) = value else { throw StrictDecodingError("expected bool") }
        return flag
    }

    static func array(_ value: JSONValue) throws(StrictDecodingError) -> [JSONValue] {
        guard case .array(let elements) = value else { throw StrictDecodingError("expected array") }
        return elements
    }

    /// `Option<T>`: absent or `null` is `nil`.
    static func optional<T>(
        _ value: JSONValue?,
        _ read: (JSONValue) throws(StrictDecodingError) -> T
    ) throws(StrictDecodingError) -> T? {
        guard let value, value != .null else { return nil }
        return try read(value)
    }
}
