/// Byte for byte what the Rust services' `serde_json` writes. A ``JSONValue/tooDeepContainer``
/// becomes `maximumNesting` nested empty arrays, so a reader hits its limit inside it again,
/// wherever it lands.
public enum JSONWriter {
    public static func string(_ value: JSONValue) -> String {
        var output: [UInt8] = []
        output.reserveCapacity(256)
        write(value, into: &output)
        return String(decoding: output, as: UTF8.self)
    }

    public static func byteCount(_ value: JSONValue) -> Int {
        var output: [UInt8] = []
        write(value, into: &output)
        return output.count
    }

    static func write(_ value: JSONValue, into output: inout [UInt8]) {
        switch value {
        case .null, .unpairedSurrogateString, .unrepresentableNumber:
            output.append(contentsOf: "null".utf8)
        case .tooDeepContainer:
            output.append(contentsOf: repeatElement(UInt8(ascii: "["), count: JSONParser.maximumNesting))
            output.append(contentsOf: repeatElement(UInt8(ascii: "]"), count: JSONParser.maximumNesting))
        case .bool(let flag):
            output.append(contentsOf: (flag ? "true" : "false").utf8)
        case .number(let number):
            writeNumber(number, into: &output)
        case .string(let text):
            writeString(text, into: &output)
        case .array(let values):
            output.append(UInt8(ascii: "["))
            for (offset, element) in values.enumerated() {
                if offset > 0 { output.append(UInt8(ascii: ",")) }
                write(element, into: &output)
            }
            output.append(UInt8(ascii: "]"))
        case .object(let members):
            output.append(UInt8(ascii: "{"))
            for (offset, member) in members.enumerated() {
                if offset > 0 { output.append(UInt8(ascii: ",")) }
                writeString(member.key, into: &output)
                output.append(UInt8(ascii: ":"))
                write(member.value, into: &output)
            }
            output.append(UInt8(ascii: "}"))
        }
    }

    static func writeNumber(_ number: JSONNumber, into output: inout [UInt8]) {
        switch number {
        case .unsigned(let value): output.append(contentsOf: String(value).utf8)
        case .negative(let value): output.append(contentsOf: String(value).utf8)
        case .double(let value):
            if value.isFinite {
                output.append(contentsOf: RustFloatFormat.serdeJSON(value).utf8)
            } else {
                output.append(contentsOf: "null".utf8)
            }
        }
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    static func writeString(_ text: String, into output: inout [UInt8]) {
        output.append(UInt8(ascii: "\""))
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "\""): output.append(contentsOf: "\\\"".utf8)
            case UInt8(ascii: "\\"): output.append(contentsOf: "\\\\".utf8)
            case 0x08: output.append(contentsOf: "\\b".utf8)
            case 0x09: output.append(contentsOf: "\\t".utf8)
            case 0x0A: output.append(contentsOf: "\\n".utf8)
            case 0x0C: output.append(contentsOf: "\\f".utf8)
            case 0x0D: output.append(contentsOf: "\\r".utf8)
            case 0x00..<0x20:
                output.append(contentsOf: "\\u00".utf8)
                output.append(hexDigits[Int(byte >> 4)])
                output.append(hexDigits[Int(byte & 0x0F)])
            default:
                output.append(byte)
            }
        }
        output.append(UInt8(ascii: "\""))
    }
}
