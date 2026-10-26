import Foundation
@testable import OpenCastAnalysis
@testable import OpenCastAnalysisProviders
@testable import OpenCastAnalysisReplay
import Testing

/// Nesting as the services' JSON reader counts it (`serde_json` 1.0.151): a
/// typed read fails at the 128th nested container, an ignored member is read
/// at any depth. The services' verdicts on deeply nested bodies and answers
/// are pinned by the `nesting-*` parity goldens; these pin the parser's own
/// rules, the sinks' handling of what it does not keep, and that no depth
/// exhausts a thread's stack.
@Suite("JSON nesting")
struct JSONNestingTests {
    enum Shape: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case arrays, objects, mixed

        var testDescription: String { rawValue }

        /// `levels` nested containers; unclosed text stops after the last
        /// opening one.
        func text(_ levels: Int, closed: Bool = true) -> String {
            switch self {
            case .arrays:
                String(repeating: "[", count: levels) + (closed ? String(repeating: "]", count: levels) : "")
            case .objects:
                String(repeating: #"{"a":"#, count: levels) + (closed ? "0" + String(repeating: "}", count: levels) : "")
            case .mixed:
                String(repeating: #"[{"a":"#, count: levels / 2) + (levels % 2 == 1 ? "[" : "")
                    + (closed ? "0" + (levels % 2 == 1 ? "]" : "") + String(repeating: "}]", count: levels / 2) : "")
            }
        }
    }

    static func arrays(_ levels: Int, inner: String = "") -> String {
        String(repeating: "[", count: levels) + inner + String(repeating: "]", count: levels)
    }

    /// The containers along the first-element chain, and what ends it.
    static func chain(_ value: JSONValue) -> (containers: Int, end: JSONValue) {
        var containers = 0
        var current = value
        while true {
            if case .array(let values) = current {
                containers += 1
                guard let first = values.first else { return (containers, current) }
                current = first
            } else if case .object(let members) = current {
                containers += 1
                guard let first = members.first else { return (containers, current) }
                current = first.value
            } else {
                return (containers, current)
            }
        }
    }

    /// `work` on a new thread whose stack is `stackKiB`.
    static func onThread(stackKiB: Int, _ work: @escaping @Sendable () -> Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            let thread = Thread { continuation.resume(returning: work()) }
            thread.stackSize = stackKiB * 1024
            thread.start()
        }
    }

    @Test("127 nested containers are values; the 128th, where serde_json's typed path stops, is kept as the marker", arguments: Shape.allCases)
    func boundary(shape: Shape) throws {
        #expect(JSONParser.maximumNesting == 128)
        for levels in [1, 126, 127] {
            let kept = Self.chain(try JSONParser.parse(shape.text(levels)))
            #expect(kept.containers == levels, "\(levels)")
            #expect(kept.end != .tooDeepContainer, "\(levels)")
        }
        for levels in [128, 129, 4096] {
            let cut = Self.chain(try JSONParser.parse(shape.text(levels)))
            #expect(cut.containers == 127, "\(levels)")
            #expect(cut.end == .tooDeepContainer, "\(levels)")
        }
    }

    @Test("Inside the marker, text is checked as a value is: the same texts accepted and rejected as two levels down")
    func ignorePathSyntax() {
        // Among them the ones the services' bridge read in a 129-deep ignored
        // member: a trailing comma, a bad literal and a raw control character
        // reject the body; `1e400` and an unpaired surrogate do not.
        for inner in ["1,", "tru", "\"\u{01}\"", #"{"a":1,}"#, "01", "1.", #""\x""#, #"{"a" 1}"#, "{1:2}", "[1 2]", "1e", "-", #""\u12""#, "]", #"{"a":}"#, ",1"] {
            #expect(throws: JSONParseError.self, "\(inner)") { try JSONParser.parse(Self.arrays(128, inner: inner)) }
        }
        for inner in ["1e400", #""\ud800""#, #"{"\ud800":0}"#, #""[[[{{""#, "-0.5e-3", #"[1,[2,{}],{"k":[null,true,false]}]"#, " ", "\t[ ]\n", #""\"""#] {
            let value = try? JSONParser.parse(Self.arrays(128, inner: inner))
            #expect(value.map { Self.chain($0).end } == .tooDeepContainer, "\(inner)")
        }
        var generator = SeededGenerator(state: 0x0128)
        let alphabet = Array(#"[]{}",: 0123456789-+.eEtrufalsn\"#)
        var accepted = 0
        for _ in 0..<20_000 {
            let inner = String((0..<Int.random(in: 0...10, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! })
            let shallow = (try? JSONParser.parse(Self.arrays(2, inner: inner))) != nil
            let deep = (try? JSONParser.parse(Self.arrays(129, inner: inner))) != nil
            #expect(shallow == deep, "\(inner)")
            if shallow { accepted += 1 }
        }
        #expect(accepted >= 1_000, "\(accepted) of 20,000 accepted")
    }

    @Test("4,096, 65,536 and 1,048,576 levels of nesting, closed and unclosed, parse on a cooperative thread", arguments: Shape.allCases)
    func deepTextOnCooperativeThread(shape: Shape) async {
        for levels in [4 * 1024, 64 * 1024, 1024 * 1024] {
            for closed in [true, false] {
                let holds = await Task.detached { () -> Bool in
                    let value = try? JSONParser.parse(shape.text(levels, closed: closed))
                    guard closed else { return value == nil }
                    return value.map { Self.chain($0) == (127, JSONValue.tooDeepContainer) } ?? false
                }.value
                #expect(holds, "\(levels) levels, closed \(closed)")
            }
        }
    }

    @Test("No depth exhausts a stack: parsing and freeing fit a quarter of a cooperative thread's 512 KiB, writing, re-reading and comparing half", arguments: Shape.allCases)
    func stackBound(shape: Shape) async {
        // Measured with a probe at 127, 128 and 1,048,576 levels: the parse
        // alone fits the 16 KiB minimum; parse and free need at most 52 KiB
        // in debug (36 KiB release), the whole round trip 116 KiB (36 KiB).
        for levels in [127, 128, 64 * 1024, 1024 * 1024] {
            let text = shape.text(levels)
            let parsed = await Self.onThread(stackKiB: 128) { (try? JSONParser.parse(text)) != nil }
            #expect(parsed, "\(levels) levels")
            let roundTrip = await Self.onThread(stackKiB: 256) {
                guard let value = try? JSONParser.parse(text) else { return false }
                return (try? JSONParser.parse(JSONWriter.string(value))) == value && value.sortedKeys() == value
            }
            #expect(roundTrip, "\(levels) levels")
        }
    }

    @Test("Every typed read rejects the marker; an ignored member holds it")
    func typedReads() throws {
        let marker = JSONValue.tooDeepContainer
        #expect(throws: StrictDecodingError.self) { try StrictDecoding.fields(marker, .init(fields: ["a"], defaulted: ["a"])) }
        #expect(throws: StrictDecodingError.self) { try StrictDecoding.array(marker) }
        #expect(throws: StrictDecodingError.self) { try StrictDecoding.string(marker) }
        #expect(throws: StrictDecodingError.self) { try StrictDecoding.int64(marker) }
        #expect(throws: StrictDecodingError.self) { try StrictDecoding.uint64(marker) }
        #expect(throws: StrictDecodingError.self) { try StrictDecoding.double(marker) }
        #expect(throws: StrictDecodingError.self) { try StrictDecoding.bool(marker) }
        #expect(throws: StrictDecodingError.self) { try StrictDecoding.optional(marker, StrictDecoding.string) }
        let holder = JSONValue.object([JSONMember("a", .integer(1)), JSONMember("nested", marker)])
        #expect(try StrictDecoding.fields(holder, .init(fields: ["a"]))["a"] == .integer(1))
        #expect(throws: StrictDecodingError.self) { try StrictDecoding.fields(holder, .init(fields: ["a"], denyUnknownFields: true)) }
        #expect(ProviderJSON.count(marker) == nil)
        #expect(!ProviderJSON.isAbsent(marker))
    }

    @Test("A Gemini error envelope reads its fields past a deep ignored member, as the services' envelope does")
    func errorEnvelope() {
        for levels in [127, 128, 1024 * 1024] {
            let details = String(repeating: "[", count: levels) + String(repeating: "]", count: levels)
            #expect(GeminiErrorClassifier.isHardQuota(#"{"error":{"status":"RESOURCE_EXHAUSTED","message":"quota","details":\#(details)}}"#), "\(levels)")
            #expect(!GeminiErrorClassifier.isHardQuota(#"{"error":{"status":"RESOURCE_EXHAUSTED","message":"quota","details":\#(String(repeating: "[", count: levels))"#), "\(levels) unclosed")
        }
    }

    @Test("The writer re-emits the marker as nesting a reader again cuts wherever it lands, and documents round trip")
    func writer() throws {
        #expect(JSONWriter.string(.tooDeepContainer) == Self.arrays(128))
        let moved = try JSONParser.parse(JSONWriter.string(.object([JSONMember("a", .tooDeepContainer)])))
        #expect(Self.chain(moved) == (127, JSONValue.tooDeepContainer))
        for text in [Self.arrays(128), Shape.objects.text(129), #"{"candidates":[],"nested":"# + Self.arrays(1 << 20) + "}"] {
            let value = try JSONParser.parse(text)
            #expect(try JSONParser.parse(JSONWriter.string(value)) == value)
        }
    }

    @Test("Every sink fails closed on the marker: the verifier is exhausted, a recording redacts it, the audit flags it")
    func sinks() throws {
        let key = RedactionPropertyTests.openAIKey
        let verifier = SecretVerifier(secrets: [key])
        let holder = JSONValue.object([JSONMember("note", .string("kept")), JSONMember("nested", .tooDeepContainer)])
        #expect(verifier.verifyRecordedJSON(.tooDeepContainer) == .exhausted)
        #expect(verifier.verifyRecordedJSON(holder) == .exhausted)
        let recording = RedactingLogger.safeRecording(holder, secrets: [key])
        #expect(recording.recorded)
        #expect(try JSONParser.parse(recording.text) == .object([
            JSONMember("note", .string("kept")), JSONMember("nested", .string(RedactingLogger.redacted)),
        ]))
        let directory = ReplayToolTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appending(path: "root"), withIntermediateDirectories: true)
        let keyFile = directory.appending(path: "key.txt")
        try key.write(to: keyFile, atomically: true, encoding: .utf8)
        try (#"{"nested":"# + Self.arrays(200) + "}").write(to: directory.appending(path: "root/deep.json"), atomically: true, encoding: .utf8)
        let counts = try Audit(arguments: try Arguments(["audit", "--key-files", keyFile.path, "--root", directory.appending(path: "root").path])).run()
        #expect(counts["strings_flagged_bound"] == .integer(1))
        #expect(counts["json_files_with_a_flagged_value"] == .integer(1))
    }
}
