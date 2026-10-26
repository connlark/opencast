import Foundation
@testable import OpenCastAnalysis
@testable import OpenCastAnalysisProviders
import Testing

/// An independent statement of the security property, by brute force: every
/// 4-scalar window of every registered secret (outside its documented
/// public prefix), looked for in every supported decoding of the final
/// bytes. It shares only the normalisation rule with ``SecretVerifier``;
/// the decoders and the search are written separately and naively.
enum FragmentOracle {
    static let publicPrefixes = ["sk-proj-", "sk-ant-", "sk-", "aizasy", "aiza", "aq.", "pplx-"]

    static func normalize(_ text: String, foldingCase: Bool = true) -> String {
        let folded = foldingCase
            ? text.decomposedStringWithCompatibilityMapping
                .folding(options: [.caseInsensitive], locale: nil)
                .decomposedStringWithCompatibilityMapping
            : text.decomposedStringWithCompatibilityMapping
        var kept = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .enclosingMark, .spacingMark, .format:
                continue
            default:
                if !scalar.properties.isDefaultIgnorableCodePoint { kept.append(scalar) }
            }
        }
        return String(kept)
    }

    static func fragments(_ secrets: [String]) -> Set<String> {
        var fragments: Set<String> = []
        for secret in secrets {
            let scalars = Array(normalize(secret).unicodeScalars)
            let text = String(String.UnicodeScalarView(scalars))
            let prefix = publicPrefixes.first { text.hasPrefix($0) }?.unicodeScalars.count ?? 0
            guard scalars.count >= 4 else {
                fragments.insert(text)
                continue
            }
            for start in 0...(scalars.count - 4) where start + 4 > prefix {
                fragments.insert(String(String.UnicodeScalarView(scalars[start..<(start + 4)])))
            }
        }
        return fragments
    }

    static func windows(_ text: String) -> [String] {
        let scalars = Array(normalize(text).unicodeScalars)
        guard scalars.count >= 4 else { return [String(String.UnicodeScalarView(scalars))] }
        return (0...(scalars.count - 4)).map { String(String.UnicodeScalarView(scalars[$0..<($0 + 4)])) }
    }

    /// The text and everything it decodes to through `\u` escapes, percent
    /// encoding, HTML entities and base64 runs, applied to the text and to
    /// its case-kept normalised form, until nothing new appears. No cutoff shared with
    /// the verifier: the oracle stops only at 64 layers or 20,000 texts, and
    /// says so (`complete` false) when it does.
    static func decodings(_ text: String) -> (texts: [String], complete: Bool) {
        var seen: Set<String> = [text]
        var layer = [text]
        for _ in 0..<64 {
            var next: [String] = []
            for item in layer {
                // What a reader decodes: the text, and the text with
                // compatibility forms and format characters normalised away
                // but its case kept (fullwidth `％`, base64 in any form).
                // Case is folded only to compare fragments.
                for source in Set([item, normalize(item, foldingCase: false)]) {
                    for decoded in [unescape(source), percent(source), entities(source), base64(source)]
                    where !decoded.isEmpty && decoded != source && !seen.contains(decoded) {
                        seen.insert(decoded)
                        next.append(decoded)
                    }
                }
            }
            if next.isEmpty { return (Array(seen), true) }
            if seen.count > 20_000 { return (Array(seen), false) }
            layer = next
        }
        return (Array(seen), false)
    }

    static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var result = text.replacing(/\\u([dD][89abAB][0-9a-fA-F]{2})\\u([dD][c-fC-F][0-9a-fA-F]{2})/) { match in
            let high = UInt32(match.output.1, radix: 16)!, low = UInt32(match.output.2, radix: 16)!
            return String(Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00))!)
        }
        result = result.replacing(/\\u([0-9a-fA-F]{4})/) { match in
            Unicode.Scalar(UInt32(match.output.1, radix: 16)!).map { String($0) } ?? ""
        }
        for (escape, value) in [("\\n", "\n"), ("\\t", "\t"), ("\\r", "\r"), ("\\b", "\u{08}"), ("\\f", "\u{0C}"),
                                ("\\\"", "\""), ("\\/", "/"), ("\\\\", "\\")] {
            result = result.replacingOccurrences(of: escape, with: value)
        }
        return result
    }

    static func percent(_ text: String) -> String {
        guard text.contains("%") || text.contains("+") else { return text }
        var bytes: [UInt8] = []
        var index = text.utf8.startIndex
        let utf8 = text.utf8
        while index < utf8.endIndex {
            let byte = utf8[index]
            if byte == UInt8(ascii: "%"), let a = utf8.index(index, offsetBy: 1, limitedBy: utf8.endIndex), a < utf8.endIndex,
               let b = utf8.index(index, offsetBy: 2, limitedBy: utf8.endIndex), b < utf8.endIndex,
               let value = UInt8(String(decoding: [utf8[a], utf8[b]], as: UTF8.self), radix: 16) {
                bytes.append(value)
                index = utf8.index(after: b)
            } else {
                bytes.append(byte == UInt8(ascii: "+") ? UInt8(ascii: " ") : byte)
                index = utf8.index(after: index)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// HTML's named references for ASCII punctuation and the common
    /// others, a superset of the verifier's.
    static let namedEntities: [(String, String)] = [
        ("amp", "&"), ("lt", "<"), ("gt", ">"), ("quot", "\""), ("apos", "'"), ("nbsp", "\u{00A0}"), ("lowbar", "_"),
        ("underbar", "_"), ("period", "."), ("sol", "/"), ("bsol", "\\"), ("plus", "+"), ("equals", "="), ("percnt", "%"),
        ("num", "#"), ("semi", ";"), ("colon", ":"), ("commat", "@"), ("dollar", "$"), ("excl", "!"), ("quest", "?"),
        ("lpar", "("), ("rpar", ")"), ("ast", "*"), ("midast", "*"), ("comma", ","), ("lsqb", "["), ("rsqb", "]"),
        ("lbrack", "["), ("rbrack", "]"), ("lcub", "{"), ("rcub", "}"), ("lbrace", "{"), ("rbrace", "}"), ("verbar", "|"),
        ("vert", "|"), ("grave", "`"), ("hat", "^"), ("tab", "\t"), ("newline", "\n"), ("hyphen", "\u{2010}"),
        ("dash", "\u{2010}"), ("minus", "\u{2212}"), ("shy", "\u{00AD}"), ("ensp", "\u{2002}"), ("emsp", "\u{2003}"),
        ("thinsp", "\u{2009}"), ("zwj", "\u{200D}"), ("zwnj", "\u{200C}"),
    ]

    static func entities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        func value(_ digits: Substring, radix: Int) -> String? {
            let trimmed = digits.drop { $0 == "0" }
            return (trimmed.isEmpty ? 0 : UInt32(trimmed, radix: radix)).flatMap(Unicode.Scalar.init).map { String($0) }
        }
        var result = text.replacing(/&#[xX]([0-9a-fA-F]+);?/) { match in value(match.output.1, radix: 16) ?? String(match.output.0) }
        result = result.replacing(/&#([0-9]+);?/) { match in value(match.output.1, radix: 10) ?? String(match.output.0) }
        for (name, value) in namedEntities {
            result = result.replacingOccurrences(of: "&\(name);", with: value, options: .caseInsensitive)
        }
        return result
    }

    /// Every run of base64 characters with one group or more (four symbols,
    /// below the verifier's six; a registered secret is never shorter than a
    /// window), split at padding, decoded at each
    /// of the four alignments: each segment alone and the segments joined.
    static func base64(_ text: String) -> String {
        func groups(_ symbols: Substring) -> Data {
            let full = symbols.count / 4 * 4
            var data = Data(base64Encoded: String(symbols.prefix(full))) ?? Data()
            let rest = symbols.suffix(symbols.count - full)
            if rest.count >= 2 {
                // Foundation rejects a short group whose unused bits are set,
                // which a reader ignores: clear them by re-encoding the bytes.
                let tail = Array(rest).map { Self.sextets.firstIndex(of: $0)! }
                var bytes = [UInt8(tail[0] << 2 | tail[1] >> 4)]
                if tail.count == 3 { bytes.append(UInt8((tail[1] & 0x0F) << 4 | tail[2] >> 2)) }
                data.append(contentsOf: bytes)
            }
            return data
        }
        var outputs: [String] = []
        for match in text.matches(of: /[A-Za-z0-9+\/=_-]+/) {
            let run = String(match.output).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            let segments = run.split(separator: "=")
            guard segments.reduce(0, { $0 + $1.count }) >= 4 else { continue }
            for alignment in 0..<4 {
                let pieces = segments.map { groups($0.dropFirst(alignment)) }
                outputs.append(String(decoding: pieces.reduce(Data(), +), as: UTF8.self))
                outputs += pieces.map { String(decoding: $0, as: UTF8.self) }
            }
        }
        return outputs.filter { !$0.isEmpty }.joined(separator: " ")
    }

    static let sextets = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

    /// The oracle's own bounds on JSON in strings, far above the verifier's
    /// (four levels, 256 KiB, depth 64): any number of levels until 64 MiB
    /// of nested JSON in all, and each text nested as deep as the parser
    /// keeps whole (127).
    static let maximumNestedBytes = 64 << 20
    static let maximumDepth = JSONParser.maximumNesting - 1

    /// The deepest `[`/`{` nesting outside strings, counted naively.
    static func depth(_ text: String) -> Int {
        var depth = 0, deepest = 0, inString = false, escaped = false
        for character in text.utf8 {
            if inString {
                if escaped { escaped = false } else if character == 0x5C { escaped = true } else if character == 0x22 { inString = false }
                continue
            }
            if character == 0x22 { inString = true }
            if character == 0x5B || character == 0x7B { depth += 1; deepest = max(deepest, depth) }
            if character == 0x5D || character == 0x7D { depth = max(depth - 1, 0) }
        }
        return deepest
    }

    /// Every text a recorded artifact holds: its bytes, and each member
    /// name and string, with JSON nested in strings opened at every level;
    /// `complete` false when the oracle's own bounds stopped it.
    static func artifactTexts(_ bytes: String) -> (texts: [String], complete: Bool) {
        var texts = [bytes]
        var nestedBytes = 0
        var complete = true
        func parse(_ text: String) -> JSONValue? {
            guard depth(text) <= maximumDepth else {
                complete = false
                return nil
            }
            return try? JSONParser.parse(text)
        }
        func walk(_ value: JSONValue) {
            switch value {
            case .string(let text):
                texts.append(text)
                guard let first = text.unicodeScalars.first(where: { !$0.properties.isWhitespace }), "{[\"".unicodeScalars.contains(first) else { return }
                nestedBytes += text.utf8.count
                guard nestedBytes <= maximumNestedBytes else {
                    complete = false
                    return
                }
                if let inner = parse(text) { walk(inner) }
            case .array(let values):
                values.forEach(walk)
            case .object(let members):
                for member in members {
                    texts.append(member.key)
                    walk(member.value)
                }
            case .tooDeepContainer:
                complete = false
            case .null, .bool, .number, .unpairedSurrogateString, .unrepresentableNumber:
                break
            }
        }
        if let value = parse(bytes) { walk(value) }
        return (texts, complete)
    }

    static func texts(ofArtifact bytes: String) -> [String] {
        artifactTexts(bytes).texts
    }

    /// The first fragment of a registered secret found in the artifact, if
    /// any, or `undecided` when the oracle's own bounds were reached. A
    /// secret too short for a window is looked for whole.
    static func leak(inArtifact bytes: String, fragments: Set<String>) -> String? {
        let (texts, complete) = artifactTexts(bytes)
        guard complete else { return undecided }
        let short = fragments.filter { $0.unicodeScalars.count < 4 }
        for text in texts {
            let (decoded, complete) = decodings(text)
            guard complete else { return undecided }
            for item in decoded {
                if let window = windows(item).first(where: fragments.contains) { return window }
                if !short.isEmpty {
                    let normalised = normalize(item)
                    if let secret = short.first(where: { normalised.contains($0) }) { return secret }
                }
            }
        }
        return nil
    }

    static let undecided = "undecided"

    /// The app-sink contract: no registered secret whole, no key shape.
    static func appLeak(_ line: String, secrets: [String]) -> String? {
        let normalised = normalize(line)
        if let secret = secrets.first(where: { normalised.contains(normalize($0)) }) { return secret }
        if line.contains(/(?:sk-|AIza)[A-Za-z0-9_\-]{16,}|pplx-[A-Za-z0-9]{24,}|AQ\.[A-Za-z0-9_.\-]{16,}/) { return "key shape" }
        return nil
    }

    static func isPlaceholder(_ text: String) -> Bool {
        guard let value = try? JSONParser.parse(text) else { return false }
        return value["redacted"] == .bool(true) && value["reason"]?.stringValue != nil
    }
}

/// A seeded generator, so the property cases are the same on every run.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

@Suite("Redaction property")
struct RedactionPropertyTests {
    static let openAIKey = "sk-" + "proj-" + String(repeating: "Lm2N", count: 10) + "Zq4W"
    static let customKey = "Qx7Lm2Np" + String(repeating: "Rt5", count: 8) + "Vw9Z"
    static let codexKey = "sk-" + "proj-QprefixabcdYabcd"

    /// Checks one input through every sink: a log line (app contract) and a
    /// recorded JSON artifact holding it as a member name and as a value
    /// (full property, or a placeholder).
    static func assertProperty(_ input: String, secrets: [String], _ name: String) {
        let line = RedactingLogger.safeLine(input, secrets: secrets)
        #expect(line == RedactingLogger.redactedLine || FragmentOracle.appLeak(line, secrets: secrets) == nil, "\(name) line: \(line)")
        let fragments = FragmentOracle.fragments(secrets)
        for value in [JSONValue.object([JSONMember("message", .string(input))]), .object([JSONMember(input, .integer(1))]),
                      .object([JSONMember("detail", .string(JSONWriter.string(.object([JSONMember("inner", .string(input))]))))])] {
            let recording = RedactingLogger.safeRecording(value, secrets: secrets)
            if recording.recorded {
                #expect(FragmentOracle.leak(inArtifact: recording.text, fragments: fragments) == nil, "\(name) recording: \(recording.text)")
            } else {
                #expect(FragmentOracle.isPlaceholder(recording.text), "\(name)")
            }
        }
        let raw = RedactingLogger.safeRecording(input, secrets: secrets)
        if raw.recorded {
            #expect(FragmentOracle.leak(inArtifact: raw.text, fragments: fragments) == nil, "\(name) raw: \(raw.text)")
        } else {
            #expect(FragmentOracle.isPlaceholder(raw.text), "\(name)")
        }
    }

    // MARK: Codex's adversarial read, verbatim

    @Test("A registered secret as a JSON member name never reaches a recording")
    func memberName() throws {
        let body = "{\"\(Self.openAIKey)\":\"invalid key\"}"
        let recording = RedactingLogger.safeRecording(body, secrets: [Self.openAIKey])
        #expect(FragmentOracle.leak(inArtifact: recording.text, fragments: FragmentOracle.fragments([Self.openAIKey])) == nil)
        #expect(!recording.text.contains(Self.openAIKey))
    }

    @Test("A fully \\u-escaped secret survives neither malformed JSON nor JSON nested in a string")
    func escapedSecret() throws {
        let escaped = Self.openAIKey.unicodeScalars.map { String(format: "\\u%04x", $0.value) }.joined()
        let trailingComma = "{\"error\": \"\(escaped)\",}"
        let malformed = RedactingLogger.safeRecording(trailingComma, secrets: [Self.openAIKey])
        #expect(!malformed.recorded && FragmentOracle.isPlaceholder(malformed.text))
        let nested = "{\"detail\": \"{\\\"k\\\": \\\"\(escaped.replacingOccurrences(of: "\\", with: "\\\\"))\\\"}\"}"
        let recording = RedactingLogger.safeRecording(nested, secrets: [Self.openAIKey])
        #expect(FragmentOracle.leak(inArtifact: recording.text, fragments: FragmentOracle.fragments([Self.openAIKey])) == nil, "\(recording.text)")
    }

    @Test("Overlap across stages: an overlapping suffix before a whole secret leaves nothing")
    func overlapAcrossStages() {
        let secret = "sk-" + "proj-ABCDxxxxsk-proj-ABCD"
        Self.assertProperty("xxxx" + secret, secrets: [secret], "overlap")
    }

    @Test("Masked context across runs, format characters and combining marks leaves nothing")
    func maskedContext() {
        let secret = "sk-" + "proj-abcdefghmiddleijklmnopuvwx"
        for text in ["sk-proj-***middle***abcd", "sk-proj-abcd***efgh…ijkl", "sk-proj-***\u{200B}uvwx", "sk-proj-***\u{0301}uvwx",
                     "abcd\u{200B}efgh", "mid\u{0301}dle"] {
            Self.assertProperty(text, secrets: [secret], text)
        }
    }

    @Test("Interior fragments of a registered secret are found")
    func interiorFragments() {
        for text in ["prefix", "Q\u{200B}prefixabcdYabcd", "a prefix here", "PREFIX"] {
            Self.assertProperty(text, secrets: [Self.codexKey], text)
            let recording = RedactingLogger.safeRecording(.object([JSONMember("m", .string(text))]), secrets: [Self.codexKey])
            #expect(!recording.text.lowercased().contains("prefix"), "\(text): \(recording.text)")
        }
    }

    @Test("Quoted, Basic, Bearer, percent-encoded query and JSON credential values are removed")
    func credentialValues() {
        let lines = ["x-api-key: \"opaque-credential\"", "Authorization: Basic dXNlcjpwYXNzd29yZA==", "Authorization: Bearer opaque-credential",
                     "GET /v1?%6Bey=opaque-credential", "GET /v1?a=1&api%5Fkey=opaque-credential", "token='opaque-credential'",
                     "api_\u{212A}ey: opaque-credential", "?\u{212A}ey=opaque-credential", "X-GOOG-API-\u{212A}EY: opaque-credential"]
        for line in lines {
            let safe = RedactingLogger.safeLine(line)
            #expect(!safe.contains("opaque-credential") && !safe.contains("dXNlcjpwYXNz"), "\(line) -> \(safe)")
        }
        for member in ["api_key", "API-Key", "token", "password", "Authorization"] {
            let recording = RedactingLogger.safeRecording("{\"\(member)\": \"opaque-credential\", \"n\": 3}", secrets: [])
            #expect(recording.recorded && !recording.text.contains("opaque-credential"), "\(member): \(recording.text)")
        }
    }

    // MARK: Every earlier finding, as the property

    static let maskStyles = ["*", "***", "****************", "…", "...", "●●●●", "•", "·····", "∗∗∗", "████", "\\u2022\\u2022"]

    static func earlierCases() -> [(String, [String], String)] {
        var cases: [(String, [String], String)] = []
        let echo = "Incorrect API key provided: sk-proj-************************************Zq4W. You can find your API key at https://platform.openai.com/account/api-keys."
        cases.append(("round 1 masked echo", [Self.openAIKey], echo))
        for mask in maskStyles {
            cases.append(("round 2 mask \(mask)", [Self.openAIKey, ProviderTestKeys.googleText], "provided: sk-proj-\(mask)Zq4W and AIzaSy\(mask)q0."))
        }
        cases.append(("round 2 masked custom key", [Self.customKey], "key Qx7Lm2Np***Vw9Z rejected"))
        cases.append(("round 2 key in a query", [ProviderTestKeys.googleText], "GET /v1beta/models?key=\(ProviderTestKeys.googleText) failed"))
        cases.append(("round 3 combining after tail", [Self.openAIKey], "tail Zq4W\u{0301} end"))
        cases.append(("round 3 combining after key", [Self.openAIKey], "echo \(Self.openAIKey)\u{0301} end"))
        cases.append(("round 3 combining in head", [Self.openAIKey], "head sk-" + "proj-Lm2NLm2\u{0301}N end"))
        cases.append(("round 4 overlapping suffix", [Self.codexKey], "QprefixabcdYabcd"))
        cases.append(("round 4 recurring tail", ["sk-" + "proj-uvAbcdwxAbcd"], "x uvAbcdwxAbcd y"))
        cases.append(("round 4 recurring head", ["sk-" + "proj-FSoYncTJ9sk-proj-FSoYn"], "x sk-" + "proj-FSoYncTJ9" + "sk-" + "proj-FSoY y"))
        cases.append(("round 4 Kelvin", [Self.openAIKey], "api_\u{212A}ey: \(Self.openAIKey)"))
        cases.append(("fullwidth", [Self.openAIKey], "ｓｋ－ｐｒｏｊ－Ｌｍ２ＮＬｍ２Ｎ"))
        cases.append(("percent-encoded", [Self.openAIKey], "q=%4C%6D%32%4E%4C%6D%32%4E"))
        cases.append(("html entities", [Self.openAIKey], "&#76;&#109;&#x32;&#x4E;&#76;m2N"))
        cases.append(("base64", [Self.openAIKey], "blob " + Data(Self.openAIKey.utf8).base64EncodedString()))
        cases.append(("base64url", [Self.openAIKey], "blob " + Data(("x" + Self.openAIKey).utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")))
        cases.append(("long s and Kelvin in a key", ["ks-" + "keysecretKSKS"], "\u{212A}\u{017F}-keysecret"))
        cases.append(("dotless and dotted i", ["Ii9-" + "IiIiIiIi"], "\u{0130}i9-\u{0131}"))
        return cases
    }

    @Test("Every earlier finding holds as the property", arguments: 0..<RedactionPropertyTests.earlierCases().count)
    func earlierFindings(index: Int) {
        let (name, secrets, input) = Self.earlierCases()[index]
        Self.assertProperty(input, secrets: secrets, name)
    }

    // MARK: Random property cases

    static func randomKey(_ generator: inout SeededGenerator) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        func run(_ count: Int) -> String { String((0..<count).map { _ in alphabet.randomElement(using: &generator)! }) }
        switch Int.random(in: 0..<3, using: &generator) {
        case 0: return "sk-" + "proj-" + run(Int.random(in: 16...48, using: &generator))
        case 1: return "AIza" + "Sy" + run(33)
        default: return run(Int.random(in: 6...30, using: &generator))
        }
    }

    /// How many transformation classes ``transformed(_:_:tally:)`` draws from.
    static let transformationClasses = 26

    /// `fragment` under one transformation class, drawn uniformly; `tally`
    /// counts the draws per class.
    static func transformed(_ fragment: String, _ generator: inout SeededGenerator, tally: inout [Int]) -> String {
        let scalars = Array(fragment.unicodeScalars)
        func interleave(_ insert: [String]) -> String {
            scalars.map { String($0) + (Bool.random(using: &generator) ? insert.randomElement(using: &generator)! : "") }.joined()
        }
        let transformation = Int.random(in: 0..<transformationClasses, using: &generator)
        tally[transformation] += 1
        switch transformation {
        case 0: return fragment
        case 1: return fragment.uppercased()
        case 2: return String(String.UnicodeScalarView(scalars.map { (0x21...0x7E).contains($0.value) ? Unicode.Scalar($0.value + 0xFEE0)! : $0 }))
        case 3: return interleave(["\u{200B}", "\u{2060}", "\u{FEFF}", "\u{00AD}", "\u{200D}"])
        case 4: return interleave(["\u{0301}", "\u{0307}", "\u{20DD}", "\u{0308}"])
        case 5: return fragment.replacingOccurrences(of: "k", with: "\u{212A}").replacingOccurrences(of: "s", with: "\u{017F}")
        case 6:
            let cut = scalars.count / 2
            let mask = ["***", "…", "●●", "...", "•"].randomElement(using: &generator)!
            return String(String.UnicodeScalarView(scalars[..<cut])) + mask + String(String.UnicodeScalarView(scalars[cut...]))
        case 7: return scalars.map { String(format: "%%%02X", $0.value & 0xFF) }.joined()
        case 8: return scalars.map { "&#\($0.value);" }.joined()
        case 9: return scalars.map { String(format: "\\u%04x", $0.value) }.joined()
        case 10: return Data(fragment.utf8).base64EncodedString()
        case 11: return JSONWriter.string(.object([JSONMember("nested", .string(fragment))]))
        case 12: return JSONWriter.string(.object([JSONMember(fragment, .integer(1))]))
        case 13: return "&#x" + scalars.map { String($0.value, radix: 16) }.joined(separator: ";&#x") + ";"
        case 14: return layered(fragment, depth: Int.random(in: 2...8, using: &generator), &generator)
        case 15:
            // Long numeric entities: leading zeros, decimal or hex, `;` optional.
            return scalars.map { scalar in
                let zeros = String(repeating: "0", count: Int.random(in: 0...40, using: &generator))
                let body = Bool.random(using: &generator) ? "#" + zeros + String(scalar.value) : "#x" + zeros + String(scalar.value, radix: 16)
                return "&" + body + (Bool.random(using: &generator) ? ";" : "")
            }.joined()
        case 16:
            // Percent encoding written in fullwidth characters.
            let encoded = scalars.map { String(format: "%%%02X", $0.value & 0xFF) }.joined()
            return String(String.UnicodeScalarView(encoded.unicodeScalars.map { Unicode.Scalar($0.value + 0xFEE0)! }))
        case 17: return Data(scalars.map { "&#\($0.value);" }.joined().utf8).base64EncodedString()
        case 18:
            let percentEncoded = scalars.map { String(format: "%%%02X", $0.value & 0xFF) }.joined()
            return JSONWriter.string(.object([JSONMember("nested", .string(percentEncoded))]))
        case 20:
            // Padded base64 encodings back to back (one piece for a fragment
            // of one scalar, as a short secret can be).
            let cut = scalars.count < 2 ? scalars.count : Int.random(in: 1..<scalars.count, using: &generator)
            return Data(String(String.UnicodeScalarView(scalars[..<cut])).utf8).base64EncodedString()
                + Data(String(String.UnicodeScalarView(scalars[cut...])).utf8).base64EncodedString()
        case 21:
            // Base64 after, and before, other base64 characters.
            let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
            func run(_ count: Int) -> String { String((0..<count).map { _ in alphabet.randomElement(using: &generator)! }) }
            let encoded = Data(fragment.utf8).base64EncodedString()
            return run(Int.random(in: 1...3, using: &generator))
                + (Bool.random(using: &generator) ? encoded : encoded.replacingOccurrences(of: "=", with: ""))
                + run(Int.random(in: 0...5, using: &generator))
        case 22:
            // Base64 written in fullwidth characters.
            let encoded = Data(fragment.utf8).base64EncodedString()
            return String(String.UnicodeScalarView(encoded.unicodeScalars.map { Unicode.Scalar($0.value + 0xFEE0)! }))
        case 23:
            // Base64 with zero-width characters between its symbols.
            return Data(fragment.utf8).base64EncodedString().unicodeScalars.map {
                String($0) + (Bool.random(using: &generator) ? ["\u{200B}", "\u{2060}", "\u{FEFF}", "\u{00AD}"].randomElement(using: &generator)! : "")
            }.joined()
        case 24:
            // Punctuation written as named references.
            return scalars.map { scalar in
                switch scalar {
                case "_": Bool.random(using: &generator) ? "&lowbar;" : "&UnderBar;"
                case ".": "&period;"
                case "-": "&#45;"
                default: String(scalar)
                }
            }.joined()
        case 25:
            // Base64 whose capitals stay as they are and whose other symbols
            // are percent, entity or `\u` encoded in fullwidth syntax.
            let encoding = Int.random(in: 0..<3, using: &generator)
            return Data(fragment.utf8).base64EncodedString().unicodeScalars.map { scalar -> String in
                guard !("A"..."Z").contains(scalar) else { return String(scalar) }
                let encoded = switch encoding {
                case 0: String(format: "%%%02X", scalar.value)
                case 1: "&#\(scalar.value);"
                default: String(format: "\\u%04x", scalar.value)
                }
                return String(String.UnicodeScalarView(encoded.unicodeScalars.map { Unicode.Scalar($0.value + 0xFEE0)! }))
            }.joined()
        default:
            return fragment.unicodeScalars.map { String($0) + "\u{200B}" }.joined().addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? fragment
        }
    }

    /// `fragment` wrapped in `depth` random layers of percent, entity,
    /// base64 and `\u` encoding.
    static func layered(_ fragment: String, depth: Int, _ generator: inout SeededGenerator) -> String {
        var text = fragment
        for _ in 0..<depth {
            let scalars = Array(text.unicodeScalars)
            text = switch Int.random(in: 0..<4, using: &generator) {
            case 0: scalars.map { String(format: "%%%02X", $0.value & 0xFF) }.joined()
            case 1: scalars.map { "&#\($0.value);" }.joined()
            case 2: Data(text.utf8).base64EncodedString()
            default: scalars.map { String(format: "\\u%04x", $0.value) }.joined()
            }
            if text.utf8.count > 60_000 { break }
        }
        return text
    }

    static func randomCase(_ seed: UInt64, tally: inout [Int]) -> (secrets: [String], text: String, json: JSONValue) {
        var generator = SeededGenerator(state: seed)
        var secrets = (0..<Int.random(in: 1...3, using: &generator)).map { _ in randomKey(&generator) }
        if Int.random(in: 0..<50, using: &generator) == 0 {
            // A key that cannot be normalised within the bounds.
            secrets.append("Qx7Lm2Np" + String(repeating: "\u{0301}", count: 33) + "Rt5Vw9Z")
        }
        if Int.random(in: 0..<50, using: &generator) == 0 {
            // A secret too short for a window, looked for whole.
            let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
            secrets.append(String((0..<Int.random(in: 1...3, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! }))
        }
        let filler = ["the ", "project ", "status=ok ", " ", "Loading... ", "***", "•", "%20", "&amp;", "id_", "12345", "1234", "{", "}",
                      "\"", "\\", "api_key: ", "Bearer ", "?key=", "&token=", "x-api-key: \"", "Basic ", "\u{212A}", "\u{017F}", "\u{0130}"]
        func piece() -> String {
            if Bool.random(using: &generator), let secret = secrets.randomElement(using: &generator) {
                let scalars = Array(secret.unicodeScalars)
                let length = Int.random(in: min(4, scalars.count)...scalars.count, using: &generator)
                let start = Int.random(in: 0...(scalars.count - length), using: &generator)
                return transformed(String(String.UnicodeScalarView(scalars[start..<(start + length)])), &generator, tally: &tally)
            }
            return filler.randomElement(using: &generator)!
        }
        let text = (0..<Int.random(in: 1...8, using: &generator)).map { _ in piece() }.joined()
        var members: [JSONMember] = []
        for _ in 0..<Int.random(in: 1...4, using: &generator) {
            let name = Bool.random(using: &generator) ? piece() : ["message", "error", "usage", "detail"].randomElement(using: &generator)!
            let value: JSONValue = switch Int.random(in: 0..<4, using: &generator) {
            case 0: .string(piece() + piece())
            case 1: .integer(Int.random(in: 0...99_999, using: &generator))
            case 2: .array([.string(piece()), .integer(Int.random(in: 0...9_999, using: &generator))])
            default: .string(JSONWriter.string(.object([JSONMember(piece(), .string(piece()))])))
            }
            members.append(JSONMember(name, value))
        }
        return (secrets, text, .object(members))
    }

    /// `REDACTION_PROPERTY_CASES` sets how many (default 500; the hand-back
    /// run used 100,000).
    /// Provider bodies carrying `text` where the recorder reads strings: a
    /// Gemini and an OpenAI answer, and both providers' error envelopes.
    static func providerBodies(_ text: String) -> [(provider: AnalysisProvider, status: Int, body: String)] {
        let gemini = JSONWriter.string(.object([
            JSONMember("candidates", .array([.object([
                JSONMember("content", .object([JSONMember("parts", .array([.object([JSONMember("text", .string(text))])]))])),
                JSONMember("finishReason", .string("STOP")),
            ])])),
            JSONMember("usageMetadata", .object([JSONMember("promptTokenCount", .integer(12)), JSONMember("candidatesTokenCount", .integer(3))])),
        ]))
        let openAI = JSONWriter.string(.object([
            JSONMember("status", .string("completed")),
            JSONMember("output", .array([.object([
                JSONMember("type", .string("message")),
                JSONMember("status", .string("completed")),
                JSONMember("content", .array([.object([JSONMember("type", .string("output_text")), JSONMember("text", .string(text))])])),
            ])])),
            JSONMember("usage", .object([JSONMember("input_tokens", .integer(12)), JSONMember("output_tokens", .integer(3))])),
        ]))
        let error = JSONWriter.string(.object([JSONMember("error", .object([
            JSONMember("status", .string(text)), JSONMember("message", .string(text)), JSONMember("type", .string(text)),
            JSONMember("code", .string(text)), JSONMember("param", .string(text)),
            JSONMember("details", .array([.object([JSONMember("reason", .string(text))])])),
        ]))]))
        return [(.google, 200, gemini), (.openai, 200, openAI), (.google, 400, error), (.openai, 401, error)]
    }

    struct PropertyRun: Sendable {
        var failures: [String]
        var undecided: Int
        var lines: [String]
    }

    @Test("No fragment of a registered secret survives any sink, or the sink failed closed")
    func randomProperty() async {
        let count = Int(ProcessInfo.processInfo.environment["REDACTION_PROPERTY_CASES"] ?? "") ?? 500
        // A long run is split into shards run side by side: each takes the
        // seeds from `REDACTION_PROPERTY_FIRST` on.
        let first = UInt64(ProcessInfo.processInfo.environment["REDACTION_PROPERTY_FIRST"] ?? "") ?? 0
        let run = await ProviderTestSupport.offPool { Self.propertyRun(first: first, count: count) }
        run.lines.forEach { print($0) }
        #expect(run.failures.isEmpty, "\(run.failures.joined(separator: "\n"))")
        // An undecided case is one the oracle could not judge: the run fails.
        #expect(run.undecided == 0, "\(run.undecided) cases undecided")
    }

    static func propertyRun(first: UInt64, count: Int) -> PropertyRun {
        var failures: [String] = []
        var suppressed = 0
        var redactedLines = 0
        var undecided = 0
        var structuredSuppressed = 0
        var tally = [Int](repeating: 0, count: Self.transformationClasses)
        func check(_ recording: AnalysisSafeRecording, _ fragments: Set<String>, _ name: String) {
            guard recording.recorded else {
                structuredSuppressed += 1
                if !FragmentOracle.isPlaceholder(recording.text) { failures.append("\(name) bad placeholder") }
                return
            }
            switch FragmentOracle.leak(inArtifact: recording.text, fragments: fragments) {
            case nil: break
            case FragmentOracle.undecided?: undecided += 1
            case let leak?: if failures.count < 10 { failures.append("\(name) leaked \(leak) in \(recording.text)") }
            }
        }
        for seed in first..<(first + UInt64(count)) {
            let (secrets, text, json) = Self.randomCase(seed &* 0x2545_F491_4F6C_DD1D &+ 7, tally: &tally)
            let fragments = FragmentOracle.fragments(secrets)
            // The structured sinks: a record verified whole as built, and the
            // recorder's exchange records of provider bodies carrying the text
            // (the key the recorder holds is the first secret).
            check(RedactingLogger.verifiedRecording(json, verifier: SecretVerifier(secrets: secrets)), fragments, "seed \(seed) structured")
            if let key = AnalysisProviderKey(secrets[0]) {
                let keyFragments = FragmentOracle.fragments([secrets[0]])
                for (provider, status, body) in Self.providerBodies(text) {
                    let record = AnalysisExchangeRecord.response(AnalysisHTTPResponse(status: status, body: Data(body.utf8)),
                                                                 provider: provider, kind: .generate, key: key)
                    check(key.verifiedRecording(record), keyFragments, "seed \(seed) \(provider.rawValue) \(status) record")
                }
            }
            let recording = RedactingLogger.safeRecording(json, secrets: secrets)
            if recording.recorded {
                switch FragmentOracle.leak(inArtifact: recording.text, fragments: fragments) {
                case nil: break
                case FragmentOracle.undecided?: undecided += 1
                case let leak?: if failures.count < 10 { failures.append("seed \(seed) leaked \(leak) in \(recording.text)") }
                }
            } else {
                suppressed += 1
                if !FragmentOracle.isPlaceholder(recording.text) { failures.append("seed \(seed) bad placeholder") }
            }
            let raw = RedactingLogger.safeRecording(text, secrets: secrets)
            if raw.recorded {
                switch FragmentOracle.leak(inArtifact: raw.text, fragments: fragments) {
                case nil: break
                case FragmentOracle.undecided?: undecided += 1
                case let leak?: if failures.count < 10 { failures.append("seed \(seed) raw leaked \(leak)") }
                }
            }
            let line = RedactingLogger.safeLine(text, secrets: secrets)
            if line == RedactingLogger.redactedLine {
                redactedLines += 1
            } else if let leak = FragmentOracle.appLeak(line, secrets: secrets), failures.count < 10 {
                failures.append("seed \(seed) line leaked \(leak): \(line)")
            }
        }
        var lines: [String] = []
        lines.append("redaction property: \(count) cases from seed \(first), \(count * 8) sink checks, \(suppressed) recordings suppressed, \(structuredSuppressed) structured records suppressed, \(redactedLines) lines redacted, \(failures.count) failures, \(undecided) undecided")
        lines.append("redaction property classes: " + tally.enumerated().map { "\($0.offset):\($0.element)" }.joined(separator: " "))
        return PropertyRun(failures: failures, undecided: undecided, lines: lines)
    }
}

extension RedactionPropertyTests {
    // MARK: Cut-offs: every bound fails closed

    @Test("Each verification bound fails closed, and the sink writes a placeholder")
    func cutOffs() {
        let verifier = SecretVerifier(secrets: [Self.openAIKey])
        // More than 32 combining marks in a row.
        #expect(verifier.verifyRecordedText("a" + String(repeating: "\u{0301}", count: 33)) == .exhausted)
        #expect(verifier.verifyRecordedText("a" + String(repeating: "\u{0301}", count: 32)) == .clean)
        // An expansion past four times the input (U+FDFA decomposes to 18 scalars).
        #expect(verifier.verifyRecordedText(String(repeating: "\u{FDFA}", count: 8)) == .exhausted)
        // JSON nested in strings past four levels.
        var nested = JSONValue.string("leaf")
        for _ in 0..<6 { nested = .string(JSONWriter.string(.object([JSONMember("n", nested)]))) }
        #expect(verifier.verifyRecordedJSON(.object([JSONMember("x", nested)])) == .exhausted)
        // Nested JSON past 256 KiB in all.
        let big = JSONValue.string(JSONWriter.string(.array((0..<6_000).map { .string("filler-\($0)-" + String(repeating: "z", count: 40)) })))
        #expect(verifier.verifyRecordedJSON(.object([JSONMember("big", big)])) == .exhausted)
        // Containers past the verifier's own depth.
        var deep = JSONValue.integer(1)
        for _ in 0..<70 { deep = .array([deep]) }
        #expect(verifier.verifyRecordedJSON(deep) == .exhausted)
        // Unpaired surrogates, parsed or in plain text.
        #expect(verifier.verifyRecordedArtifact(#"{"m":"\ud800x"}"#) == .exhausted)
        #expect(verifier.verifyRecordedText(#"x \ud800 y"#) == .exhausted)
        // The decoding budget.
        var budget = SecretVerifier.Budget(text: "")
        budget.bytes = 10
        #expect(verifier.verifyText(String(repeating: "abc ", count: 10), depth: 0, nested: 0, budget: &budget) == .exhausted)
        // Each bound reaches the sink as a placeholder.
        for value in [JSONValue.object([JSONMember("x", nested)]), deep] {
            let recording = RedactingLogger.safeRecording(value, secrets: [Self.openAIKey])
            #expect(!recording.recorded || FragmentOracle.leak(inArtifact: recording.text, fragments: FragmentOracle.fragments([Self.openAIKey])) == nil)
            #expect(recording.recorded || FragmentOracle.isPlaceholder(recording.text))
        }
        let marks = RedactingLogger.safeRecording(.object([JSONMember("m", .string("a" + String(repeating: "\u{0301}", count: 40)))]), secrets: [Self.openAIKey])
        #expect(marks.recorded && marks.text.contains(RedactingLogger.redacted))
        #expect(RedactingLogger.safeRecording(#"{"m":"\ud800x"}"#, secrets: [Self.openAIKey]).recorded == true)
        #expect(RedactingLogger.safeRecording("not json at all", secrets: [Self.openAIKey]).reason == "not_json")
    }

    @Test("Mask collapsing never hides a literal fragment: the raw folded text is checked too")
    func collapseKeepsLiterals() {
        let secret = "sk-" + "proj-QQxxxxRRxxxxSS"
        let verifier = SecretVerifier(secrets: [secret])
        #expect(verifier.verifyRecordedText("sk-proj-xxxx") == .secretFragment)
        #expect(verifier.verifyRecordedText("rrxxxx") == .secretFragment)
        #expect(verifier.verifyRecordedText("....") == .clean)
    }

    @Test("Normalisation sees Kelvin, long s, sharp s, dotted capital I and combining sequences")
    func normalisation() {
        let verifier = SecretVerifier(secrets: ["kssi-" + "abcdKSSIwxyz"])
        for text in ["\u{212A}\u{017F}\u{017F}i", "\u{00DF}i-a", "a\u{0301}b\u{0307}c\u{0308}d", "\u{0301}abcd", "abcd\u{0301}", "\u{0130}wxy", "KSSI",
                     "ａｂｃｄ", "a\u{200B}b\u{2060}c\u{FEFF}d"] {
            #expect(verifier.verifyRecordedText(text) == .secretFragment, "\(text)")
        }
        #expect(verifier.verifyRecordedText("unrelated words") == .clean)
    }

    // MARK: Closed vocabularies in app sinks

    @Test("A send record holds closed values and numbers only, and its model id is checked")
    func sendRecordFields() {
        let record = AnalysisProviderSendRecord(
            provider: .google, modelID: "gemini-3.8-flash", feature: .adDetection, purpose: .adWindow(index: 0), sendIndex: 0,
            status: 200, finishReason: .stop, failure: nil, usage: AnalysisBilledUsage(input: 1, cached: 0, write: 0, output: 2, reasoning: 0),
            pacedSeconds: 0, exchangeSeconds: 1
        )
        // Every field is a number, a Boolean, a closed enum or the checked model id.
        let types = Mirror(reflecting: record).children.map { ($0.label ?? "", String(describing: type(of: $0.value))) }
        let allowed: Set<String> = ["AnalysisProvider", "AnalysisFeature", "Purpose", "Int", "Optional<Int>", "Optional<AnalysisFinishReason>",
                                    "Optional<AnalysisProviderFailure>", "Bool", "Optional<AnalysisBilledUsage>", "Double"]
        for (label, type) in types where label != "modelID" {
            #expect(allowed.contains(type), "\(label): \(type)")
        }
        #expect(types.filter { $0.1.contains("String") }.map(\.0) == ["modelID"])
        for bad in ["model with spaces", "x/../y", String(repeating: "a", count: 65), "", "sk-" + "proj-" + String(repeating: "a", count: 10) + "?"] {
            let scrubbed = AnalysisProviderSendRecord(
                provider: .openai, modelID: bad, feature: .adDetection, purpose: .adWindow(index: 0), sendIndex: 0, status: nil,
                finishReason: nil, failure: .timeout, usage: nil, pacedSeconds: 0, exchangeSeconds: 0
            )
            #expect(scrubbed.modelID == AnalysisProviderSendRecord.invalidModelID, "\(bad)")
        }
        #expect(AnalysisProviderSendRecord.scrubbedModelID("gpt-6.1-sol:2026") == "gpt-6.1-sol:2026")
    }

    @Test("Every transport log line is a closed grammar of names and simple values")
    func logLinesAreClosed() async throws {
        let fixture = try ProviderTestSupport.providerFixture("error-cases.json")
        let grammar = /^(send|pacing)( [a-z_]+=[A-Za-z0-9_.:-]+)+$/
        var lines: [String] = []
        for item in fixture["cases"]?.arrayValue ?? [] {
            let provider = try #require(AnalysisProvider(rawValue: item["provider"]?.stringValue ?? ""))
            guard let status = item["status"].flatMap({ ProviderJSON.count($0) }), let body = item["body"]?.stringValue else { continue }
            let sink = CollectingLogSink()
            let transport = try ProviderErrorTableTests.transport(
                provider, ScriptedHTTPClient(status: Int(status), body: body, retryAfter: item["retry_after"]?.stringValue),
                observer: AnalysisProviderSendLog(), sink: sink
            )
            _ = await ProviderTestSupport.sendResult(transport, try ProviderTestSupport.adWindowRequest(model: ProviderErrorTableTests.entry(provider)))
            lines += sink.all
        }
        #expect(lines.count > 20)
        for line in lines {
            #expect(line.wholeMatch(of: grammar) != nil, "\(line)")
        }
    }

    // MARK: Complexity

    /// CPU seconds `work` takes on this thread, the best of three.
    static func seconds(_ work: () -> Void) -> Double {
        var best = Double.infinity
        for _ in 0..<3 {
            let started = ProviderTestSupport.threadCPUSeconds()
            work()
            best = min(best, ProviderTestSupport.threadCPUSeconds() - started)
        }
        return best
    }

    @Test("Every sink is linear: repeated keys, combining marks, nested JSON and base64 at doubling sizes")
    func linearity() async {
        func family(_ name: String, _ work: @escaping @Sendable (Int) -> Void) async {
            let (small, large) = await ProviderTestSupport.offPool { (Self.seconds { work(4_000) }, Self.seconds { work(32_000) }) }
            print("linearity \(name): 4k \(small) s, 32k \(large) s")
            // Linear work grows 8x here and quadratic work 64x; the bound sits
            // between them with room for a loaded machine.
            #expect(large < 3, "\(name): \(large) s at 32k")
            #expect(large < 32 * max(small, 0.005), "\(name): \(small) s -> \(large) s for 8x the size")
        }
        await family("repeated key, text") { size in
            let key = "sk-" + "proj-" + String(repeating: "a", count: size / 2)
            _ = RedactingLogger.safeLine(String(repeating: "a", count: size), secrets: [key])
        }
        await family("repeated key, JSON") { size in
            let key = "sk-" + "proj-" + String(repeating: "a", count: size / 2)
            _ = RedactingLogger.safeRecording(.object([JSONMember("t", .string(String(repeating: "a", count: size)))]), secrets: [key])
        }
        await family("combining marks") { size in
            _ = RedactingLogger.safeRecording(.object([JSONMember("t", .string(String(repeating: "a\u{0301}", count: size / 2)))]), secrets: [Self.openAIKey])
        }
        await family("nested JSON") { size in
            var value = JSONValue.string(String(repeating: "word ", count: size / 20))
            for _ in 0..<3 { value = .string(JSONWriter.string(.object([JSONMember("n", value), JSONMember("pad", .string(String(repeating: "q", count: size / 8)))]))) }
            _ = RedactingLogger.safeRecording(.object([JSONMember("t", value)]), secrets: [Self.openAIKey])
        }
        await family("base64 runs") { size in
            _ = RedactingLogger.safeRecording(.object([JSONMember("t", .string(String(repeating: "QUJDREVGR0hJSktMTU5PUA== ", count: size / 25)))]),
                                              secrets: [Self.openAIKey])
        }
        await family("ellipses") { size in
            _ = RedactingLogger.safeLine(String(repeating: "a...", count: size / 4), secrets: [Self.openAIKey])
        }
    }
}

extension RedactionPropertyTests {
    static func percentLayers(_ text: String, _ count: Int) -> String {
        var value = text
        for _ in 0..<count { value = value.unicodeScalars.map { String(format: "%%%02X", $0.value & 0xFF) }.joined() }
        return value
    }

    static func assertRecordingHolds(_ value: JSONValue, secrets: [String], _ name: String) {
        let recording = RedactingLogger.safeRecording(value, secrets: secrets)
        if recording.recorded {
            #expect(FragmentOracle.leak(inArtifact: recording.text, fragments: FragmentOracle.fragments(secrets)) == nil, "\(name): \(recording.text)")
        } else {
            #expect(FragmentOracle.isPlaceholder(recording.text), "\(name)")
        }
    }

    @Test("Encodings beyond the layer limit fail closed instead of passing")
    func beyondLayerLimit() {
        let key = Self.openAIKey
        for layers in [4, 5, 8] {
            Self.assertRecordingHolds(.object([JSONMember("m", .string(Self.percentLayers(key, layers)))]), secrets: [key], "percent x\(layers)")
            var generator = SeededGenerator(state: UInt64(layers))
            Self.assertRecordingHolds(.object([JSONMember("m", .string(Self.layered(key, depth: layers, &generator)))]), secrets: [key], "mixed x\(layers)")
        }
        let mixed = Data(Self.percentLayers(key.unicodeScalars.map { "&#\($0.value);" }.joined(), 2).utf8).base64EncodedString()
        Self.assertRecordingHolds(.object([JSONMember("m", .string(mixed))]), secrets: [key], "entity, percent x2, base64")
    }

    @Test("Long numeric entities with leading zeros, decimal or hex, are decoded")
    func longEntities() {
        let key = Self.openAIKey
        let decimal = key.unicodeScalars.map { "&#000000000000\($0.value);" }.joined()
        let hex = key.unicodeScalars.map { "&#x" + String(repeating: "0", count: 30) + String($0.value, radix: 16) }.joined()
        let tooLong = "&#" + String(repeating: "0", count: 200) + "115;"
        for (name, text) in [("decimal", decimal), ("hex without semicolons", hex), ("past the bound", tooLong + key)] {
            Self.assertRecordingHolds(.object([JSONMember("m", .string(text))]), secrets: [key], name)
        }
        #expect(SecretVerifier(secrets: [key]).verifyRecordedText(decimal) == .secretFragment)
    }

    @Test("Normalisation and decoding compose: fullwidth percent, entities inside base64, percent inside nested JSON")
    func composedTransformations() {
        let key = Self.openAIKey
        let percent = Self.percentLayers(key, 1)
        let fullwidth = String(String.UnicodeScalarView(percent.unicodeScalars.map { Unicode.Scalar($0.value + 0xFEE0)! }))
        let entityBase64 = Data(key.unicodeScalars.map { "&#\($0.value);" }.joined().utf8).base64EncodedString()
        let nested = JSONWriter.string(.object([JSONMember("inner", .string(percent))]))
        for (name, text) in [("fullwidth percent", fullwidth), ("entities in base64", entityBase64), ("percent in nested JSON", nested)] {
            #expect(SecretVerifier(secrets: [key]).verifyRecordedText(text) != .clean, "\(name)")
            Self.assertRecordingHolds(.object([JSONMember("m", .string(text))]), secrets: [key], name)
        }
    }

    @Test("Base64 is read at its own alignment: after padding, after base64 characters, fullwidth, with zero-width characters")
    func base64Alignment() {
        let key = Self.openAIKey
        let encoded = Data(key.utf8).base64EncodedString()
        let entityBase64 = Data(key.unicodeScalars.map { "&#\($0.value);" }.joined().utf8).base64EncodedString()
        let other = Data("UoeVAH22n3".utf8).base64EncodedString()
        let escapedOther = other.unicodeScalars.map { String(format: "\\u%04x", $0.value) }.joined()
        let cases = [
            // The shape the 100,000-case run found: a padded encoding, then
            // entities in base64 straight after it.
            ("after padding", other + entityBase64),
            ("escaped, after padding", escapedOther + entityBase64),
            ("after base64 characters", "id_" + encoded),
            ("between digits", "12345" + encoded.replacingOccurrences(of: "=", with: "") + "x"),
            ("unpadded back to back", Data("hello world".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "") + encoded),
            ("fullwidth", String(String.UnicodeScalarView(encoded.unicodeScalars.map { Unicode.Scalar($0.value + 0xFEE0)! }))),
            ("zero-width", encoded.unicodeScalars.map { String($0) + "\u{200B}" }.joined()),
        ]
        for (name, text) in cases {
            #expect(SecretVerifier(secrets: [key]).verifyRecordedText(text) != .clean, "\(name)")
            let recording = RedactingLogger.safeRecording(.object([JSONMember("m", .string(text))]), secrets: [key])
            #expect(!recording.recorded || recording.text == #"{"m":"[REDACTED]"}"#, "\(name): \(recording.text)")
            Self.assertRecordingHolds(.object([JSONMember("m", .string(text))]), secrets: [key], name)
        }
    }

    @Test("A key that cannot be normalised within the bounds still protects: every sink fails closed")
    func unnormalisableKey() {
        let key = "Qx7Lm2Np" + String(repeating: "\u{0301}", count: 33) + "Rt5Vw9Z"
        let exposed = "Qx7Lm2NpRt5Vw9Z"
        let recording = RedactingLogger.safeRecording(.object([JSONMember("m", .string(exposed))]), secrets: [key])
        #expect(!recording.recorded && !recording.text.contains(exposed), "\(recording.text)")
        #expect(RedactingLogger.safeLine("echo \(exposed)", secrets: [key]) == RedactingLogger.redactedLine)
    }

    @Test("Unregistered credentials: short and quoted scheme values, whole masked tokens, in both sinks")
    func unregisteredCredentials() {
        let cases: [(String, [String])] = [
            ("Authorization: Basic YTpi", ["YTpi"]), ("Basic YTpi", ["YTpi"]), ("Bearer abc", ["abc"]),
            ("Bearer \"opaque-credential\"", ["opaque-credential"]), ("bearer 'opaque-credential'", ["opaque-credential"]),
            ("sk-proj-***middle***abcd", ["middle", "abcd"]), ("sk-proj-***\u{200B}uvwx", ["uvwx"]), ("sk-proj-\u{200B}***uvwx", ["uvwx"]),
            ("sk-proj-***\u{0301}uvwx", ["uvwx"]), ("AIza…middle…wxyz", ["middle", "wxyz"]),
        ]
        for (text, secrets) in cases {
            let line = RedactingLogger.safeLine(text)
            let recording = RedactingLogger.safeRecording(.object([JSONMember("m", .string(text))]), secrets: [])
            for secret in secrets {
                #expect(!line.contains(secret), "line \(text) -> \(line)")
                #expect(!recording.text.contains(secret), "recording \(text) -> \(recording.text)")
            }
        }
    }

    @Test("A model id that is the key never reaches an observer")
    func modelIDIsVerified() async throws {
        var model = ProviderTestSupport.openAIEntry()
        model.modelID = ProviderTestKeys.openAIText
        let log = AnalysisProviderSendLog()
        let transport = try ProviderTestSupport.openAITransport(ScriptedHTTPClient(status: 500, body: "{}"), observer: log)
        _ = await ProviderTestSupport.sendResult(transport, try ProviderTestSupport.adWindowRequest(model: model))
        #expect(log.sends.map(\.modelID) == [AnalysisProviderSendRecord.invalidModelID])
        var google = ProviderTestSupport.googleEntry()
        google.modelID = ProviderTestKeys.googleText
        let googleLog = AnalysisProviderSendLog()
        let gemini = try ProviderTestSupport.googleTransport(ScriptedHTTPClient(status: 500, body: "{}"), observer: googleLog)
        _ = await ProviderTestSupport.sendResult(gemini, try ProviderTestSupport.adWindowRequest(model: google))
        #expect(googleLog.sends.map(\.modelID) == [AnalysisProviderSendRecord.invalidModelID])
    }

    @Test("Query parameters and long combining runs are linear")
    func queriesAndMarksAreLinear() async {
        func family(_ name: String, _ work: @escaping @Sendable (Int) -> Void) async {
            let (small, large) = await ProviderTestSupport.offPool { (Self.seconds { work(4_000) }, Self.seconds { work(32_000) }) }
            print("linearity \(name): 4k \(small) s, 32k \(large) s")
            #expect(large < 3, "\(name): \(large) s at 32k")
            #expect(large < 32 * max(small, 0.005), "\(name): \(small) s -> \(large) s for 8x the size")
        }
        await family("query delimiters") { size in
            _ = RedactingLogger.safeRecording(.object([JSONMember("u", .string("=" + String(repeating: "?a", count: size / 2)))]), secrets: [Self.openAIKey])
        }
        await family("query delimiters, line") { size in
            _ = RedactingLogger.safeLine("=" + String(repeating: "&a", count: size / 2), secrets: [Self.openAIKey])
        }
        let reorder = (0..<5).map { "a" + String(repeating: "\u{0316}\u{0301}", count: 2_000 << $0) }
        await family("combining marks to reorder, verifier") { size in
            _ = SecretVerifier(secrets: [Self.openAIKey]).verifyRecordedText(reorder[size == 4_000 ? 0 : 3])
        }
        await family("combining marks to reorder, sinks") { size in
            let text = reorder[size == 4_000 ? 0 : 3]
            _ = RedactingLogger.safeRecording(.object([JSONMember("m", .string(text))]), secrets: [Self.openAIKey])
            _ = RedactingLogger.safeLine(text, secrets: [Self.openAIKey])
        }
        await family("layered encodings") { size in
            var generator = SeededGenerator(state: 9)
            _ = RedactingLogger.safeRecording(.object([JSONMember("m", .string(Self.layered(String(repeating: "x", count: size / 64), depth: 3, &generator)))]),
                                              secrets: [Self.openAIKey])
        }
    }
}
