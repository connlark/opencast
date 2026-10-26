import Foundation
@testable import OpenCastAnalysis
@testable import OpenCastAnalysisProviders
import Testing

/// Nesting is measured the way the parser reads it (strings and escapes
/// honoured), on provider bodies and on the answers they carry; base64
/// decodings are verified one at a time; and every bound the contract
/// states is pinned at its number.
@Suite("Bounds contract")
struct BoundsContractTests {
    static let key = RedactionPropertyTests.openAIKey

    /// `depth` arrays, each holding a string with a closing bracket before
    /// the next: counted without honouring strings, every level cancels.
    static func cancelling(_ depth: Int) -> String {
        String(repeating: #"["]","#, count: depth) + "0" + String(repeating: "]", count: depth)
    }

    static func geminiBody(answer: String, extra: String = "") -> String {
        String(JSONWriter.string(.object([
            JSONMember("candidates", .array([.object([
                JSONMember("content", .object([JSONMember("parts", .array([.object([JSONMember("text", .string(answer))])]))])),
                JSONMember("finishReason", .string("STOP")),
            ])])),
        ])).dropLast()) + extra + "}"
    }

    static func openAIBody(answer: String) -> String {
        JSONWriter.string(.object([
            JSONMember("status", .string("completed")),
            JSONMember("output", .array([.object([
                JSONMember("type", .string("message")),
                JSONMember("status", .string("completed")),
                JSONMember("content", .array([.object([
                    JSONMember("type", .string("output_text")),
                    JSONMember("text", .string(answer)),
                ])])),
            ])])),
        ]))
    }

    static func runAds(_ body: String, provider: AnalysisProvider) async throws -> AnalysisOutcome {
        let model = provider == .google ? ProviderTestSupport.googleEntry() : ProviderTestSupport.openAIEntry()
        let client = ScriptedHTTPClient(status: 200, body: body)
        let transport: any AnalysisProviderTransport = provider == .google
            ? try ProviderTestSupport.googleTransport(client)
            : try ProviderTestSupport.openAITransport(client)
        return await AnalysisRunner(transport: transport, clock: AnalysisFrozenClock())
            .detectAds(try ProviderTestSupport.carouselRequest, policy: AdDetectionAnalysisPolicy.service.with(model: model))
    }

    // MARK: Nesting in the provider layer

    @Test("Brackets inside strings are not containers: a shallow body with bracket-heavy strings is the provider's answer")
    func bracketsInsideStrings() {
        let brackets = String(repeating: "[", count: 4096) + String(repeating: "]", count: 4096)
        let body = Self.geminiBody(answer: #"{"spans":[]}"#, extra: #","note":"\#(brackets)""#)
        #expect(GeminiAnalysisTransport.interpret(body).finishReason == .stop)
        let answer = JSONWriter.string(.object([JSONMember("spans", .array([])), JSONMember("note", .string(brackets))]))
        #expect(OpenAIResponsesMapping.answer(fromBody: Self.openAIBody(answer: answer)).answer.finishReason == "STOP")
        #expect(GeminiAnalysisTransport.interpret(Self.geminiBody(answer: answer)).finishReason == .stop)
    }

    @Test("Quoted brackets and escaped quotes do not cancel real nesting, in a body or in the answer it carries")
    func cancellationDoesNotHideNesting() async throws {
        for depth in [200, 4096] {
            let deep = Self.cancelling(depth)
            let escaped = String(repeating: #"["\"]","#, count: depth) + "0" + String(repeating: "]", count: depth)
            for (name, body) in [
                ("ignored field", Self.geminiBody(answer: #"{"spans":[]}"#, extra: #","x":\#(deep)"#)),
                ("escaped quotes in an ignored field", Self.geminiBody(answer: #"{"spans":[]}"#, extra: #","x":\#(escaped)"#)),
                ("answer", Self.geminiBody(answer: deep)),
                ("answer with escaped quotes", Self.geminiBody(answer: escaped)),
            ] {
                #expect(GeminiAnalysisTransport.interpret(body).finishReason == .malformedResponse, "gemini \(name) \(depth)")
                guard case .failed = try await Self.runAds(body, provider: .google) else {
                    Issue.record("gemini \(name) \(depth) was not refused")
                    continue
                }
            }
            for answer in [deep, escaped] {
                let body = Self.openAIBody(answer: answer)
                #expect(OpenAIResponsesMapping.answer(fromBody: body).answer.finishReason == AnalysisFinishReason.malformedResponse.rawValue)
                guard case .failed = try await Self.runAds(body, provider: .openai) else {
                    Issue.record("openai answer \(depth) was not refused")
                    continue
                }
            }
            let error = #"{"error":{"status":"RESOURCE_EXHAUSTED","message":"quota","details":\#(deep)}}"#
            #expect(GeminiProviderErrors.classify(status: 429, retryAfter: nil, body: error).listener == .rateLimited)
        }
    }

    @Test("A megabyte of mixed quoted and bare brackets is refused in linear time, never parsed")
    func megabyteOfBrackets() async throws {
        let (verdicts, elapsed) = await ProviderTestSupport.offPool { () -> ([Bool], Duration) in
            // Bare opening brackets, each followed by a quoted closing one.
            let unit = #"["]","#
            let mixed = String(repeating: unit, count: (1 << 20) / unit.utf8.count)
            // The work runs on this one thread, so its CPU time is the
            // algorithm's cost whatever else the machine is doing; a
            // wall clock on a shared CI runner once read 38 seconds for it.
            let start = Self.threadCPUTime()
            let verdicts = [
                GeminiAnalysisTransport.interpret(Self.geminiBody(answer: "{}", extra: #","x":\#(mixed)"#)).finishReason == .malformedResponse,
                GeminiAnalysisTransport.interpret(Self.geminiBody(answer: mixed)).finishReason == .malformedResponse,
                OpenAIResponsesMapping.answer(fromBody: Self.openAIBody(answer: mixed)).answer.finishReason
                    == AnalysisFinishReason.malformedResponse.rawValue,
                SecretVerifier(secrets: [Self.key]).verifyRecordedText(mixed) == .exhausted,
            ]
            return (verdicts, Self.threadCPUTime() - start)
        }
        for (index, holds) in verdicts.enumerated() {
            #expect(holds, "check \(index)")
        }
        // Linear scans of a megabyte take a few seconds of CPU; a parse that
        // nested the brackets would not finish in hours.
        #expect(elapsed < .seconds(60))
    }

    /// CPU time consumed by the calling thread so far.
    static func threadCPUTime() -> Duration {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return .seconds(time.tv_sec) + .nanoseconds(time.tv_nsec)
    }

    @Test("An unterminated string in a provider body is malformed, whatever follows it")
    func unterminatedString() {
        let body = String(Self.geminiBody(answer: "{}").dropLast()) + #","x":"\#(String(repeating: "[", count: 4096))"#
        #expect(GeminiAnalysisTransport.interpret(body).finishReason == .malformedResponse)
    }

    // MARK: Base64 decodings verified one at a time

    @Test("Each base64 alignment and segment is verified by structure on its own: credential objects, deep nesting")
    func base64DecodingsSeparately() {
        let verifier = SecretVerifier(secrets: [Self.key])
        let credential = Data(#"{"api_key":"opaque-credential-value"}"#.utf8).base64EncodedString()
        let deep = Data((String(repeating: "[", count: 100) + String(repeating: "]", count: 100)).utf8).base64EncodedString()
        let other = Data(#"{"a":1}"#.utf8).base64EncodedString()
        for prefix in ["", "x", "id", "idx"] {
            #expect(verifier.verifyRecordedText(prefix + credential) == .secretFragment, "credential after \(prefix.count)")
            #expect(verifier.verifyRecordedText(prefix + deep) == .exhausted, "deep after \(prefix.count)")
        }
        #expect(verifier.verifyRecordedText(other + credential) == .secretFragment, "credential after another padded encoding")
        #expect(verifier.verifyRecordedText(other + deep) == .exhausted, "deep after another padded encoding")
    }

    // MARK: The oracle's escapes

    @Test("The oracle reads every short escape the verifier reads")
    func oracleShortEscapes() {
        for (escape, value) in [(#"\r"#, "\r"), (#"\b"#, "\u{08}"), (#"\f"#, "\u{0C}"), (#"\n"#, "\n"), (#"\t"#, "\t"), (#"\/"#, "/")] {
            #expect(FragmentOracle.unescape("a\(escape)b") == "a\(value)b", "\(escape)")
        }
    }

    // MARK: Every stated bound, at its number

    static func arrays(_ depth: Int) -> String {
        String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
    }

    @Test("JSON nesting: 64 containers in a recording, counted across JSON held in strings; 128 in a provider body")
    func nestingBounds() {
        let verifier = SecretVerifier(secrets: [Self.key])
        #expect(verifier.verifyRecordedArtifact(Self.arrays(64)) == .clean)
        #expect(verifier.verifyRecordedArtifact(Self.arrays(65)) == .exhausted)
        // One object, then the arrays a string in it holds.
        #expect(verifier.verifyRecordedArtifact(JSONWriter.string(.object([JSONMember("m", .string(Self.arrays(63)))]))) == .clean)
        #expect(verifier.verifyRecordedArtifact(JSONWriter.string(.object([JSONMember("m", .string(Self.arrays(64)))]))) == .exhausted)
        #expect(verifier.verifyRecordedText(Self.arrays(64)) == .clean)
        #expect(verifier.verifyRecordedText(Self.arrays(65)) == .exhausted)
        // The direct JSON entry point counts containers the same way.
        func nest(_ depth: Int) -> JSONValue { (0..<depth).reduce(JSONValue.array([])) { inner, _ in .array([inner]) } }
        #expect(verifier.verifyRecordedJSON(nest(63)) == .clean)
        #expect(verifier.verifyRecordedJSON(nest(64)) == .exhausted)
        #expect(verifier.verifyRecordedJSON(.object([JSONMember("m", .string(Self.arrays(63)))])) == .clean)
        #expect(verifier.verifyRecordedJSON(.object([JSONMember("m", .string(Self.arrays(64)))])) == .exhausted)
        #expect(ProviderJSON.parse(Self.arrays(128)) != nil)
        #expect(ProviderJSON.parse(Self.arrays(129)) == nil)
        // The body's object, then the arrays of an ignored field.
        #expect(GeminiAnalysisTransport.interpret(Self.geminiBody(answer: "{}", extra: #","x":\#(Self.arrays(127))"#)).finishReason == .stop)
        #expect(GeminiAnalysisTransport.interpret(Self.geminiBody(answer: "{}", extra: #","x":\#(Self.arrays(128))"#)).finishReason == .malformedResponse)
    }

    @Test("JSON held in strings: four levels and 256 KiB in all")
    func nestedJSONBounds() {
        let verifier = SecretVerifier(secrets: [Self.key])
        func nested(_ levels: Int) -> JSONValue {
            var value = JSONValue.object([JSONMember("v", .integer(1))])
            for _ in 0..<levels { value = .object([JSONMember("v", .string(JSONWriter.string(value)))]) }
            return value
        }
        #expect(verifier.verifyRecordedJSON(nested(4)) == .clean)
        #expect(verifier.verifyRecordedJSON(nested(5)) == .exhausted)
        // A JSON text of exactly `bytes` in a string, made of text no
        // decoder reads, so only the byte bound decides.
        func held(_ bytes: Int) -> JSONValue {
            let filler = String(repeating: "a.", count: (bytes - 4) / 2) + (bytes.isMultiple(of: 2) ? "" : "a")
            let text = #"[""# + filler + #""]"#
            #expect(text.utf8.count == bytes)
            return .object([JSONMember("m", .string(text))])
        }
        #expect(verifier.verifyRecordedJSON(held(256 * 1024)) == .clean)
        #expect(verifier.verifyRecordedJSON(held(256 * 1024 + 1)) == .exhausted)
    }

    @Test("Normalisation: four scalars out per scalar in, plus 16; 32 combining marks in a run")
    func normalisationBounds() {
        let unit = "\u{FDFA}"
        let expansion = unit.decomposedStringWithCompatibilityMapping.folding(options: [.caseInsensitive], locale: nil)
            .decomposedStringWithCompatibilityMapping.unicodeScalars.count
        #expect(expansion > 4)
        for count in 1...6 {
            let text = String(repeating: unit, count: count)
            #expect((SecretNormalization.stripped(text) != nil) == (expansion * count <= 4 * count + 16), "\(count)")
        }
        #expect(SecretNormalization.stripped("a" + String(repeating: "\u{0301}", count: 32)) != nil)
        #expect(SecretNormalization.stripped("a" + String(repeating: "\u{0301}", count: 33)) == nil)
    }

    @Test("Decoding: numeric entities of 64 digits, four layers")
    func decodingBounds() {
        let verifier = SecretVerifier(secrets: [Self.key])
        let digits64 = "&#" + String(repeating: "0", count: 61) + "115;"
        let digits65 = "&#" + String(repeating: "0", count: 62) + "115;"
        #expect(verifier.verifyRecordedText(digits64) == .clean)
        #expect(verifier.verifyRecordedText(digits65) == .exhausted)
        // Four layers are decoded; a decoding still left at the fourth
        // fails closed.
        func percent(_ text: String) -> String { text.unicodeScalars.map { String(format: "%%%02X", $0.value) }.joined() }
        #expect(verifier.verifyRecordedText(percent(percent(percent(percent("xA"))))) == .clean)
        #expect(verifier.verifyRecordedText(percent(percent(percent(percent("x%41"))))) == .exhausted)
    }

    @Test("Work: 16 times the bytes verified plus 64 KiB, for every entry point")
    func workBound() async {
        // Work is counted in bytes of candidates: a three-byte text with no
        // decoding needs exactly three.
        let verifier = SecretVerifier(secrets: [Self.key])
        var exact = SecretVerifier.Budget(text: "")
        exact.bytes = 3
        #expect(verifier.verifyText("abc", depth: 0, nested: 0, budget: &exact) == .clean)
        var short = SecretVerifier.Budget(text: "")
        short.bytes = 2
        #expect(verifier.verifyText("abc", depth: 0, nested: 0, budget: &short) == .exhausted)
        // A JSON value's budget scales with its size: this one needs about
        // 20 MB of work (base64 read at four alignments), more than any
        // fixed 16 MiB budget, and less than 16 times its 2 MB.
        let verdict = await ProviderTestSupport.offPool { () -> SecretVerifier.Verdict in
            var bytes: [UInt8] = []
            for index in 0..<1_500_000 {
                let letter = (index * 7 + index / 26) % 26
                bytes.append(UInt8(97 + letter))
            }
            return SecretVerifier(secrets: [Self.key]).verifyRecordedJSON(.string(Data(bytes).base64EncodedString()))
        }
        #expect(verdict == .clean)
        for bytes in [0, 1, 1000, 1 << 20] {
            #expect(SecretVerifier.Budget(text: String(repeating: "a", count: bytes)).bytes == 16 * bytes + 64 * 1024)
            #expect(SecretVerifier.Budget.workBound(bytes: bytes) == 16 * bytes + 64 * 1024)
        }
        // A JSON value gets its serialized size's budget, not a constant.
        let value = JSONValue.object([JSONMember("m", .string(String(repeating: "abc", count: 1000)))])
        #expect(SecretVerifier.Budget(value: value).bytes == 16 * JSONWriter.byteCount(value) + 64 * 1024)
    }
}
