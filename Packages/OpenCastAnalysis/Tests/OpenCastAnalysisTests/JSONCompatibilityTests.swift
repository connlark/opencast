@testable import OpenCastAnalysis
import Testing

/// The reader and writer follow the services' JSON library; the full
/// differential runs (30,013 floats, 20,041 number literals) are in the
/// parity evidence, these pin the rules.
@Suite("JSON compatibility")
struct JSONCompatibilityTests {
    @Test("Numbers keep the unsigned / negative / binary64 classification", arguments: [
        ("0", JSONNumber.unsigned(0)),
        ("18446744073709551615", .unsigned(.max)),
        ("-9223372036854775808", .negative(.min)),
        ("-0", .double(-0.0)),
        ("12.0", .double(12)),
        ("1e2", .double(100)),
        ("18446744073709551616", .double(18446744073709551616)),
    ])
    func numberClassification(text: String, expected: JSONNumber) throws {
        #expect(try JSONParser.parse(text) == .number(expected))
    }

    @Test("Malformed text is rejected", arguments: [
        "", "01", "1.", ".5", "1e", "[1,]", "{\"a\":1,}", "nul", "\"\u{01}\"", "\"\\x\"", "1 2", "\u{FEFF}{}",
    ])
    func rejects(text: String) {
        #expect(throws: JSONParseError.self) { try JSONParser.parse(text) }
    }

    @Test("Out-of-range numbers and unpaired surrogates are markers, not errors")
    func markers() throws {
        #expect(try JSONParser.parse("1e400") == .unrepresentableNumber)
        #expect(try JSONParser.parse("\"\\ud800\"") == .unpairedSurrogateString)
        #expect(try JSONParser.parse("\"\\ud83d\\ude00\"") == .string("😀"))
        #expect(try JSONParser.parse("1e-400") == .number(.double(0)))
    }

    @Test("Floats use the services' layout", arguments: [
        (1.0, "1.0"), (0.1, "0.1"), (1e-5, "0.00001"), (1e-6, "1e-6"), (1e15, "1000000000000000.0"),
        (1e16, "1e+16"), (1.5e-7, "1.5e-7"), (-0.0, "-0.0"), (123.456, "123.456"), (1.7976931348623157e308, "1.7976931348623157e+308"),
    ])
    func floatLayout(value: Double, text: String) {
        #expect(JSONWriter.string(.double(value)) == text)
    }

    @Test("Fixed decimals round the exact binary value, ties to even", arguments: [
        (0.0625, 3, "0.062"), (0.1875, 3, "0.188"), (2.5, 0, "2"), (1.5, 0, "2"), (0.0005, 3, "0.001"),
        (1.0005, 3, "1.000"), (9.9995, 3, "9.999"), (5018.697142857143, 3, "5018.697"), (1e21, 3, "1000000000000000000000.000"),
    ])
    func fixedDecimals(value: Double, places: Int, text: String) {
        #expect(RustFloatFormat.fixed(value, places: places) == text)
    }

    @Test("Strings escape only quotes, backslashes and C0 controls")
    func stringEscapes() {
        #expect(JSONWriter.string(.string("a\"b\\c/\u{7F}é\n\u{01}")) == #""a\"b\\c/\#u{7F}é\n\u0001""#)
    }

    @Test("Strict reads follow derive rules")
    func strictReads() throws {
        let shape = StrictDecoding.Shape(fields: ["a", "b"], defaulted: ["b"], denyUnknownFields: true)
        #expect(try StrictDecoding.fields(try JSONParser.parse("[1]"), shape)["a"] == .integer(1))
        #expect(throws: StrictDecodingError.self) { try StrictDecoding.fields(try JSONParser.parse("{\"a\":1,\"a\":2}"), shape) }
        #expect(throws: StrictDecodingError.self) { try StrictDecoding.fields(try JSONParser.parse("{\"a\":1,\"c\":2}"), shape) }
        #expect(throws: StrictDecodingError.self) { try StrictDecoding.fields(try JSONParser.parse("[1,2,3]"), shape) }
        #expect(throws: StrictDecodingError.self) { try StrictDecoding.int64(.number(.double(12))) }
        #expect(throws: StrictDecodingError.self) { try StrictDecoding.string(.unpairedSurrogateString) }
        #expect(try StrictDecoding.double(.number(.unsigned(3))) == 3)
        let unreadableKey = try JSONParser.parse(#"{"a":1,"x":{"\ud800":0}}"#)
        #expect(try StrictDecoding.fields(unreadableKey, .init(fields: ["a"]))["a"] == .integer(1))
        #expect(throws: StrictDecodingError.self) {
            try StrictDecoding.fields(try JSONParser.parse(#"{"a":1,"\ud800":0}"#), .init(fields: ["a"]))
        }
    }
}
