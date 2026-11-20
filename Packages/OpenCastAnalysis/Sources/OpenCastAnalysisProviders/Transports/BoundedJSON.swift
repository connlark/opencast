import OpenCastAnalysis

/// Nesting is measured before parsing, since what is read is walked level by level afterwards
/// (verification, redaction, writing).
public enum BoundedJSON {
    public enum Result: Sendable, Equatable {
        case value(JSONValue)
        /// Nested past the bound: a resource limit, not a verdict on the text.
        case tooDeep
        case invalid
    }

    public enum Scan: Sendable, Equatable {
        case within
        case tooDeep
        case unterminatedString
    }

    public static func parse(_ text: String, maximumDepth: Int) -> Result {
        switch scan(text, maximumDepth: maximumDepth) {
        case .within:
            guard let value = try? JSONParser.parse(text) else { return .invalid }
            return .value(value)
        case .tooDeep:
            return .tooDeep
        case .unterminatedString:
            return .invalid
        }
    }

    /// The parser stops at the first byte it cannot read, no deeper than this count by then, so
    /// `.within` bounds the nesting of what it reads for any text, JSON or not.
    public static func scan(_ text: String, maximumDepth: Int) -> Scan {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in text.utf8 {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                if depth > maximumDepth { return .tooDeep }
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                depth = max(depth - 1, 0)
            default:
                break
            }
        }
        return inString ? .unterminatedString : .within
    }
}
