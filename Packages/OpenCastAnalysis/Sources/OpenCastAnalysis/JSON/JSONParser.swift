/// Why a JSON text was rejected. The cases mirror the parse errors of the
/// Rust services' JSON reader closely enough to tell classes apart in tests;
/// callers only ever need "rejected".
public enum JSONParseError: Error, Sendable, Equatable {
    case unexpectedEnd
    case unexpectedCharacter(offset: Int)
    case invalidNumber(offset: Int)
    case numberOutOfRange(offset: Int)
    case invalidEscape(offset: Int)
    case controlCharacterInString(offset: Int)
    case invalidKey(offset: Int)
    case trailingCharacters(offset: Int)
}

/// A strict JSON reader with the acceptance rules of the Rust services'
/// `serde_json` build (no `float_roundtrip`, no `arbitrary_precision`):
/// only space, tab, newline and carriage return are whitespace; numbers
/// follow RFC 8259 and are classified unsigned / negative / binary64 with
/// the same overflow and power-of-ten conversion; strings reject raw control
/// characters and malformed escapes; and nothing but whitespace may follow
/// the value. Three things the Rust reader only rejects when a typed field
/// reads them are kept as markers instead of errors, because an ignored
/// field accepts them: unpaired surrogate escapes, out-of-range numbers and
/// containers nested past its recursion limit. The Rust reader's typed path
/// stops at the `maximumNesting`th nested container, while its ignore path
/// reads any depth; so the containers around that level become values, and
/// one at that level is read with the same syntax checks, however deep it
/// goes, and kept as ``JSONValue/tooDeepContainer``. The reader never
/// recurses, so no input can exhaust the stack.
public enum JSONParser {
    /// The nesting level at which the Rust reader's typed path fails
    /// (`serde_json`'s recursion limit, 128): 127 nested containers are
    /// read as values.
    public static let maximumNesting = 128

    public static func parse(_ text: String) throws(JSONParseError) -> JSONValue {
        var bytes = Array(text.utf8)
        bytes.append(0)
        var reader = Reader(bytes: bytes, end: bytes.count - 1)
        reader.skipWhitespace()
        let value = try reader.parseValue()
        reader.skipWhitespace()
        guard reader.index == reader.end else {
            throw .trailingCharacters(offset: reader.index)
        }
        return value
    }

    private struct Reader {
        /// An open array or object and what has been read of it.
        struct Container {
            let isObject: Bool
            var values: [JSONValue] = []
            var members: [JSONMember] = []
            /// The name of the member whose value is being read.
            var key = ""
            var keyHasUnpairedSurrogate = false

            var closer: UInt8 { isObject ? UInt8(ascii: "}") : UInt8(ascii: "]") }
        }

        let bytes: [UInt8]
        let end: Int
        var index = 0

        init(bytes: [UInt8], end: Int) {
            self.bytes = bytes
            self.end = end
        }

        var peek: UInt8? { index < end ? bytes[index] : nil }

        mutating func skipWhitespace() {
            while index < end {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D: index += 1
                default: return
                }
            }
        }

        /// One value at `index`, whitespace already skipped. Open containers
        /// are kept on a heap stack, never on the call stack.
        mutating func parseValue() throws(JSONParseError) -> JSONValue {
            var open: [Container] = []
            while true {
                guard let byte = peek else { throw .unexpectedEnd }
                var value: JSONValue
                if byte == UInt8(ascii: "[") || byte == UInt8(ascii: "{") {
                    if open.count + 1 >= JSONParser.maximumNesting {
                        try skipContainer()
                        value = .tooDeepContainer
                    } else {
                        index += 1
                        skipWhitespace()
                        var container = Container(isObject: byte == UInt8(ascii: "{"))
                        if peek == container.closer {
                            index += 1
                            value = container.isObject ? .object([]) : .array([])
                        } else {
                            if container.isObject {
                                let key = try parseKey()
                                container.key = key.stringValue ?? "\u{FFFD}"
                                container.keyHasUnpairedSurrogate = key == .unpairedSurrogateString
                            }
                            open.append(container)
                            continue
                        }
                    }
                } else {
                    value = try parseScalar()
                }
                // Hand the value to the innermost open container, closing
                // every container that ends after it.
                while true {
                    guard !open.isEmpty else { return value }
                    let last = open.count - 1
                    if open[last].isObject {
                        var member = JSONMember(open[last].key, value)
                        member.keyHasUnpairedSurrogate = open[last].keyHasUnpairedSurrogate
                        open[last].members.append(member)
                    } else {
                        open[last].values.append(value)
                    }
                    skipWhitespace()
                    guard let next = peek else { throw .unexpectedEnd }
                    index += 1
                    if next == open[last].closer {
                        let closed = open.removeLast()
                        value = closed.isObject ? .object(closed.members) : .array(closed.values)
                        continue
                    }
                    guard next == UInt8(ascii: ",") else { throw .unexpectedCharacter(offset: index - 1) }
                    skipWhitespace()
                    if open[last].isObject {
                        let key = try parseKey()
                        open[last].key = key.stringValue ?? "\u{FFFD}"
                        open[last].keyHasUnpairedSurrogate = key == .unpairedSurrogateString
                    } else if peek == UInt8(ascii: "]") {
                        throw .unexpectedCharacter(offset: index)
                    }
                    break
                }
            }
        }

        /// The container at `index`, read the way the Rust reader's ignore
        /// path reads one: the same syntax as a value, any depth, nothing
        /// kept.
        mutating func skipContainer() throws(JSONParseError) {
            var closers: [UInt8] = []
            while true {
                guard let byte = peek else { throw .unexpectedEnd }
                if byte == UInt8(ascii: "[") || byte == UInt8(ascii: "{") {
                    index += 1
                    skipWhitespace()
                    let closer = byte == UInt8(ascii: "{") ? UInt8(ascii: "}") : UInt8(ascii: "]")
                    if peek == closer {
                        index += 1
                    } else {
                        if closer == UInt8(ascii: "}") { _ = try parseKey() }
                        closers.append(closer)
                        continue
                    }
                } else {
                    _ = try parseScalar()
                }
                while true {
                    guard let closer = closers.last else { return }
                    skipWhitespace()
                    guard let next = peek else { throw .unexpectedEnd }
                    index += 1
                    if next == closer {
                        closers.removeLast()
                        continue
                    }
                    guard next == UInt8(ascii: ",") else { throw .unexpectedCharacter(offset: index - 1) }
                    skipWhitespace()
                    if closer == UInt8(ascii: "}") {
                        _ = try parseKey()
                    } else if peek == UInt8(ascii: "]") {
                        throw .unexpectedCharacter(offset: index)
                    }
                    break
                }
            }
        }

        /// A member name and its colon, with the whitespace after it.
        mutating func parseKey() throws(JSONParseError) -> JSONValue {
            guard let quote = peek else { throw .unexpectedEnd }
            guard quote == UInt8(ascii: "\"") else { throw .invalidKey(offset: index) }
            index += 1
            let key = try parseString()
            skipWhitespace()
            guard let colon = peek else { throw .unexpectedEnd }
            guard colon == UInt8(ascii: ":") else { throw .unexpectedCharacter(offset: index) }
            index += 1
            skipWhitespace()
            return key
        }

        /// Anything but an array or an object.
        mutating func parseScalar() throws(JSONParseError) -> JSONValue {
            guard let byte = peek else { throw .unexpectedEnd }
            switch byte {
            case UInt8(ascii: "n"):
                try expectLiteral("null")
                return .null
            case UInt8(ascii: "t"):
                try expectLiteral("true")
                return .bool(true)
            case UInt8(ascii: "f"):
                try expectLiteral("false")
                return .bool(false)
            case UInt8(ascii: "-"):
                index += 1
                return try parseNumberValue(positive: false)
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                return try parseNumberValue(positive: true)
            case UInt8(ascii: "\""):
                index += 1
                return try parseString()
            default:
                throw .unexpectedCharacter(offset: index)
            }
        }

        mutating func expectLiteral(_ literal: StaticString) throws(JSONParseError) {
            let start = literal.utf8Start
            for offset in 0..<literal.utf8CodeUnitCount {
                guard let byte = peek else { throw .unexpectedEnd }
                guard byte == start[offset] else { throw .unexpectedCharacter(offset: index) }
                index += 1
            }
        }

        // MARK: Strings

        mutating func parseString() throws(JSONParseError) -> JSONValue {
            var scalars = String.UnicodeScalarView()
            var unpaired = false
            var runStart = index
            while true {
                guard index < end else { throw .unexpectedEnd }
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    appendRun(from: runStart, to: index, into: &scalars)
                    index += 1
                    return unpaired ? .unpairedSurrogateString : .string(String(scalars))
                }
                if byte == UInt8(ascii: "\\") {
                    appendRun(from: runStart, to: index, into: &scalars)
                    index += 1
                    if try parseEscape(into: &scalars) == false { unpaired = true }
                    runStart = index
                    continue
                }
                if byte < 0x20 { throw .controlCharacterInString(offset: index) }
                index += 1
            }
        }

        func appendRun(from start: Int, to stop: Int, into scalars: inout String.UnicodeScalarView) {
            guard start < stop else { return }
            let text = String(decoding: bytes[start..<stop], as: UTF8.self)
            scalars.append(contentsOf: text.unicodeScalars)
        }

        /// Decodes one escape after the backslash. Returns false when a
        /// `\u` escape produced an unpaired surrogate.
        mutating func parseEscape(into scalars: inout String.UnicodeScalarView) throws(JSONParseError) -> Bool {
            guard let byte = peek else { throw .unexpectedEnd }
            index += 1
            switch byte {
            case UInt8(ascii: "\""): scalars.append("\"")
            case UInt8(ascii: "\\"): scalars.append("\\")
            case UInt8(ascii: "/"): scalars.append("/")
            case UInt8(ascii: "b"): scalars.append("\u{08}")
            case UInt8(ascii: "f"): scalars.append("\u{0C}")
            case UInt8(ascii: "n"): scalars.append("\n")
            case UInt8(ascii: "r"): scalars.append("\r")
            case UInt8(ascii: "t"): scalars.append("\t")
            case UInt8(ascii: "u"):
                let unit = try parseHex4()
                switch unit {
                case 0xD800...0xDBFF:
                    guard index + 1 < end,
                          bytes[index] == UInt8(ascii: "\\"),
                          bytes[index + 1] == UInt8(ascii: "u")
                    else { return false }
                    let save = index
                    index += 2
                    let low = try parseHex4()
                    guard (0xDC00...0xDFFF).contains(low) else {
                        index = save
                        return false
                    }
                    let value = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                    scalars.append(Unicode.Scalar(value)!)
                case 0xDC00...0xDFFF:
                    return false
                default:
                    scalars.append(Unicode.Scalar(UInt32(unit))!)
                }
            default:
                throw .invalidEscape(offset: index - 1)
            }
            return true
        }

        mutating func parseHex4() throws(JSONParseError) -> UInt16 {
            var value: UInt16 = 0
            for _ in 0..<4 {
                guard let byte = peek else { throw .unexpectedEnd }
                let digit: UInt8
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
                default: throw .invalidEscape(offset: index)
                }
                value = value << 4 | UInt16(digit)
                index += 1
            }
            return value
        }

        // MARK: Numbers

        /// A number literal; out of range becomes a marker after the rest of
        /// the literal is consumed, as the Rust reader's ignore path does.
        mutating func parseNumberValue(positive: Bool) throws(JSONParseError) -> JSONValue {
            let start = index
            do {
                return .number(try parseInteger(positive: positive))
            } catch .numberOutOfRange {
                index = start
                try skipNumberLiteral()
                return .unrepresentableNumber
            }
        }

        mutating func skipNumberLiteral() throws(JSONParseError) {
            func isDigit(_ byte: UInt8?) -> Bool {
                byte.map { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) } ?? false
            }
            while isDigit(peek) { index += 1 }
            if peek == UInt8(ascii: ".") {
                index += 1
                while isDigit(peek) { index += 1 }
            }
            if let byte = peek, byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
                index += 1
                if let sign = peek, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") { index += 1 }
                while isDigit(peek) { index += 1 }
            }
        }

        static func overflows(_ value: UInt64, adding digit: UInt64) -> Bool {
            value >= UInt64.max / 10 && (value > UInt64.max / 10 || digit > UInt64.max % 10)
        }

        mutating func parseInteger(positive: Bool) throws(JSONParseError) -> JSONNumber {
            guard let first = peek else { throw .unexpectedEnd }
            index += 1
            switch first {
            case UInt8(ascii: "0"):
                if let next = peek, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(next) {
                    throw .invalidNumber(offset: index)
                }
                return try parseNumber(positive: positive, significand: 0)
            case UInt8(ascii: "1")...UInt8(ascii: "9"):
                var significand = UInt64(first - UInt8(ascii: "0"))
                while let byte = peek, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
                    let digit = UInt64(byte - UInt8(ascii: "0"))
                    if Self.overflows(significand, adding: digit) {
                        return .double(try parseLongInteger(positive: positive, significand: significand))
                    }
                    index += 1
                    significand = significand * 10 + digit
                }
                return try parseNumber(positive: positive, significand: significand)
            default:
                throw .invalidNumber(offset: index - 1)
            }
        }

        mutating func parseNumber(positive: Bool, significand: UInt64) throws(JSONParseError) -> JSONNumber {
            switch peek {
            case UInt8(ascii: "."):
                return .double(try parseDecimal(positive: positive, significand: significand, exponentBeforePoint: 0))
            case UInt8(ascii: "e"), UInt8(ascii: "E"):
                return .double(try parseExponent(positive: positive, significand: significand, startingExponent: 0))
            default:
                if positive { return .unsigned(significand) }
                let negated = Int64(bitPattern: significand) &* -1
                if negated >= 0 { return .double(-Double(significand)) }
                return .negative(negated)
            }
        }

        mutating func parseDecimal(
            positive: Bool,
            significand initial: UInt64,
            exponentBeforePoint: Int32
        ) throws(JSONParseError) -> Double {
            index += 1
            var significand = initial
            var exponentAfterPoint: Int32 = 0
            while let byte = peek, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
                let digit = UInt64(byte - UInt8(ascii: "0"))
                if Self.overflows(significand, adding: digit) {
                    return try parseDecimalOverflow(
                        positive: positive,
                        significand: significand,
                        exponent: exponentBeforePoint &+ exponentAfterPoint
                    )
                }
                index += 1
                significand = significand * 10 + digit
                exponentAfterPoint -= 1
            }
            if exponentAfterPoint == 0 {
                if peek == nil { throw .unexpectedEnd }
                throw .invalidNumber(offset: index)
            }
            let exponent = exponentBeforePoint &+ exponentAfterPoint
            if let byte = peek, byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
                return try parseExponent(positive: positive, significand: significand, startingExponent: exponent)
            }
            return try doubleFromParts(positive: positive, significand: significand, exponent: exponent)
        }

        mutating func parseExponent(
            positive: Bool,
            significand: UInt64,
            startingExponent: Int32
        ) throws(JSONParseError) -> Double {
            index += 1
            var positiveExponent = true
            if peek == UInt8(ascii: "+") {
                index += 1
            } else if peek == UInt8(ascii: "-") {
                index += 1
                positiveExponent = false
            }
            guard let first = peek else { throw .unexpectedEnd }
            index += 1
            guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first) else {
                throw .invalidNumber(offset: index - 1)
            }
            var exponent = Int32(first - UInt8(ascii: "0"))
            while let byte = peek, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
                index += 1
                let digit = Int32(byte - UInt8(ascii: "0"))
                if exponent >= Int32.max / 10 && (exponent > Int32.max / 10 || digit > Int32.max % 10) {
                    return try parseExponentOverflow(
                        positive: positive,
                        zeroSignificand: significand == 0,
                        positiveExponent: positiveExponent
                    )
                }
                exponent = exponent * 10 + digit
            }
            let finalExponent = positiveExponent
                ? startingExponent.addingReportingOverflow(exponent).overflow
                    ? Int32.max : startingExponent + exponent
                : startingExponent.subtractingReportingOverflow(exponent).overflow
                    ? Int32.min : startingExponent - exponent
            return try doubleFromParts(positive: positive, significand: significand, exponent: finalExponent)
        }

        mutating func parseLongInteger(positive: Bool, significand: UInt64) throws(JSONParseError) -> Double {
            var exponent: Int32 = 0
            while true {
                switch peek {
                case .some(UInt8(ascii: "0")...UInt8(ascii: "9")):
                    index += 1
                    exponent += 1
                case .some(UInt8(ascii: ".")):
                    return try parseDecimal(positive: positive, significand: significand, exponentBeforePoint: exponent)
                case .some(UInt8(ascii: "e")), .some(UInt8(ascii: "E")):
                    return try parseExponent(positive: positive, significand: significand, startingExponent: exponent)
                default:
                    return try doubleFromParts(positive: positive, significand: significand, exponent: exponent)
                }
            }
        }

        mutating func parseDecimalOverflow(
            positive: Bool,
            significand: UInt64,
            exponent: Int32
        ) throws(JSONParseError) -> Double {
            while let byte = peek, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
                index += 1
            }
            if let byte = peek, byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
                return try parseExponent(positive: positive, significand: significand, startingExponent: exponent)
            }
            return try doubleFromParts(positive: positive, significand: significand, exponent: exponent)
        }

        mutating func parseExponentOverflow(
            positive: Bool,
            zeroSignificand: Bool,
            positiveExponent: Bool
        ) throws(JSONParseError) -> Double {
            if !zeroSignificand && positiveExponent { throw .numberOutOfRange(offset: index) }
            while let byte = peek, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
                index += 1
            }
            return positive ? 0.0 : -0.0
        }

        /// The Rust reader's conversion: the significand rounded to binary64,
        /// then one multiply or divide by a correctly rounded power of ten,
        /// stepping by 1e308 below the table.
        func doubleFromParts(positive: Bool, significand: UInt64, exponent initial: Int32) throws(JSONParseError) -> Double {
            var value = Double(significand)
            var exponent = initial
            while true {
                let magnitude = exponent == Int32.min ? Int(Int32.max) + 1 : Int(abs(exponent))
                if magnitude < PowersOfTen.table.count {
                    let power = PowersOfTen.table[magnitude]
                    if exponent >= 0 {
                        value *= power
                        if value.isInfinite { throw .numberOutOfRange(offset: index) }
                    } else {
                        value /= power
                    }
                    break
                }
                if value == 0 { break }
                if exponent >= 0 { throw .numberOutOfRange(offset: index) }
                value /= 1e308
                exponent += 308
            }
            return positive ? value : -value
        }
    }
}

/// 1e0 through 1e308, each the correctly rounded binary64 value of its
/// decimal literal.
enum PowersOfTen {
    static let table: [Double] = (0...308).map { Double("1e\($0)")! }
}
