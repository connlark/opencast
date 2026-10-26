import OpenCastAnalysis

/// JSON read with its nesting bounded before it is parsed. Provider bodies
/// and recordings nest a handful of levels, and what is read from them is
/// walked level by level afterwards (verification, redaction, writing), so
/// text from a provider or a recording is measured first, the way the
/// parser reads it: one linear pass lexes strings (a backslash escapes the
/// next character) and counts `[` and `{` outside them, and text nested
/// past the bound is refused without parsing.
public enum BoundedJSON {
    public enum Result: Sendable, Equatable {
        case value(JSONValue)
        /// Nested past the bound: a resource limit, not a verdict on the text.
        case tooDeep
        case invalid
    }

    public enum Scan: Sendable, Equatable {
        /// Never nested past the bound, every string closed.
        case within
        case tooDeep
        /// A string still open at the end: the text is not JSON.
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

    /// Containers counted as the parser opens them: a bracket inside a
    /// string is text, and a closing bracket never takes the count below
    /// zero. The parser stops at the first byte it cannot read, at a depth
    /// no greater than this count has reached by then, so `.within` bounds
    /// the nesting of what it reads for any text, JSON or not.
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
