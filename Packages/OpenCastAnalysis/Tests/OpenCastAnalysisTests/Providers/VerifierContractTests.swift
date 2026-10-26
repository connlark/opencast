import Foundation
@testable import OpenCastAnalysis
@testable import OpenCastAnalysisProviders
@testable import OpenCastAnalysisReplay
import Testing

/// The verifier's contract at its edges: decoders read case-kept text,
/// every candidate is checked by structure, depth is bounded before any
/// recursion, recognised but invalid encodings fail closed, normalisation
/// and registration stay linear; the redactor's credential glue and quoted
/// values; and the oracle's own reach.
@Suite("Verifier contract")
struct VerifierContractTests {
    static let key = RedactionPropertyTests.openAIKey
    static let fullwidthOffset: UInt32 = 0xFEE0

    static func fullwidth(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { (0x21...0x7E).contains($0.value) ? Unicode.Scalar($0.value + fullwidthOffset)! : $0 }))
    }

    /// Every other scalar of `text` written with `encode`, the rest as it is.
    static func partly(_ text: String, _ encode: (Unicode.Scalar) -> String) -> String {
        text.unicodeScalars.enumerated().map { $0.offset.isMultiple(of: 2) ? encode($0.element) : String($0.element) }.joined()
    }

    static func recordingHolds(_ text: String, secrets: [String], _ name: String) {
        let recording = RedactingLogger.safeRecording(.object([JSONMember("m", .string(text))]), secrets: secrets)
        #expect(!recording.recorded || recording.text == #"{"m":"[REDACTED]"}"#, "\(name): \(recording.text.prefix(200))")
    }

    @Test("Decoders read case-kept normalised text: fullwidth percent, entity and \\u around base64")
    func caseKeptDecoding() {
        // Every third character of the key is a capital, so every base64
        // group of it starts with a capital symbol. The capitals stay as
        // they are and every other symbol is encoded in fullwidth syntax:
        // only normalising exposes the encoding, and folding case then
        // breaks every group, so only the case-kept form decodes the key.
        let key = "Qx7Rm2Sn4Tp8Uq1Vr3Ws5Xt6Yu9Zv0"
        let encoded = Data(key.utf8).base64EncodedString()
        func partlyEncoded(_ encode: (Unicode.Scalar) -> String) -> String {
            encoded.unicodeScalars.map { ("A"..."Z").contains($0) ? String($0) : Self.fullwidth(encode($0)) }.joined()
        }
        let cases = [
            ("percent", partlyEncoded { String(format: "%%%02X", $0.value) }),
            ("entity", partlyEncoded { "&#\($0.value);" }),
            ("\\u", partlyEncoded { String(format: "\\u%04x", $0.value) }),
        ]
        for (name, text) in cases {
            #expect(SecretVerifier(secrets: [key]).verifyRecordedText(text) == .secretFragment, "\(name)")
            Self.recordingHolds(text, secrets: [key], "fullwidth \(name)")
        }
    }

    @Test("Every decoded or normalised candidate is checked by structure: encoded credential members, fullwidth depth")
    func structuralCandidates() {
        let verifier = SecretVerifier(secrets: [Self.key])
        let credential = #"{"api_key":"opaque-credential-value"}"#
        let percent = credential.unicodeScalars.map { String(format: "%%%02X", $0.value) }.joined()
        let escaped = #"{\"token\":\"opaque-credential-value\"}"#
        #expect(verifier.verifyRecordedText(percent) == .secretFragment)
        #expect(verifier.verifyRecordedText(escaped) == .secretFragment)
        #expect(verifier.verifyRecordedText(Self.fullwidth(credential)) == .secretFragment)
        let deep = Self.fullwidth(String(repeating: "[", count: 80) + String(repeating: "]", count: 80))
        #expect(verifier.verifyRecordedText(deep) == .exhausted)
        for (name, text) in [("percent", percent), ("escaped", escaped), ("deep", deep)] {
            Self.recordingHolds(text, secrets: [Self.key], name)
        }
    }

    @Test("Deep nesting fails closed before any recursion: 8 KiB and 1 MiB of brackets")
    func deepNesting() async {
        for count in [8 * 1024, 1024 * 1024] {
            let verdicts = await ProviderTestSupport.offPool { () -> [Bool] in
                let verifier = SecretVerifier(secrets: [Self.key])
                let brackets = String(repeating: "[", count: count)
                let closed = brackets + String(repeating: "]", count: count)
                return [
                    verifier.verifyRecordedText(brackets) == .exhausted,
                    verifier.verifyRecordedJSON(.string(brackets)) == .exhausted,
                    verifier.verifyRecordedArtifact(brackets) != .clean,
                    !RedactingLogger.safeRecording(brackets, secrets: [Self.key]).recorded,
                    verifier.verifyRecordedArtifact(closed) == .exhausted,
                    !RedactingLogger.safeRecording(closed, secrets: [Self.key]).recorded,
                ]
            }
            for (index, holds) in verdicts.enumerated() {
                #expect(holds, "check \(index) at \(count) brackets")
            }
        }
    }

    /// A provider body nested `depth` levels in an ignored field, or with an
    /// answer text that is.
    static func deepGeminiBody(_ depth: Int, inText: Bool) -> String {
        let nest = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        return inText
            ? #"{"candidates":[{"content":{"parts":[{"text":"\#(nest)"}]},"finishReason":"STOP"}]}"#
            : #"{"candidates":[{"content":{"parts":[{"text":"{}"}]},"finishReason":"STOP"}],"ignored":\#(nest)}"#
    }

    @Test("A provider body nested past the bound never reaches a recursive parser: a malformed answer, an error classified by status")
    func deepProviderBodies() async throws {
        for depth in [4 * 1024, 64 * 1024] {
            for inText in [false, true] {
                let body = Self.deepGeminiBody(depth, inText: inText)
                let interpreted = GeminiAnalysisTransport.interpret(body)
                #expect(interpreted.finishReason == .malformedResponse, "gemini depth \(depth) in text \(inText)")
                let model = ProviderTestSupport.googleEntry()
                let transport = try ProviderTestSupport.googleTransport(ScriptedHTTPClient(status: 200, body: body))
                let outcome = await AnalysisRunner(transport: transport, clock: AnalysisFrozenClock())
                    .detectAds(try ProviderTestSupport.carouselRequest, policy: AdDetectionAnalysisPolicy.service.with(model: model))
                guard case .failed = outcome else {
                    Issue.record("gemini depth \(depth) in text \(inText): \(outcome)")
                    continue
                }
            }
            let nest = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
            let openAI = #"{"status":"completed","output":[{"type":"message","status":"completed","content":[{"type":"output_text","text":"\#(nest)"}]}]}"#
            #expect(OpenAIResponsesMapping.answer(fromBody: openAI).answer.finishReason == AnalysisFinishReason.malformedResponse.rawValue)
            let error = #"{"error":{"status":"RESOURCE_EXHAUSTED","message":"quota","details":\#(nest)}}"#
            #expect(GeminiProviderErrors.classify(status: 429, retryAfter: nil, body: error).listener == .rateLimited)
            #expect(OpenAIProviderErrors.classify(status: 401, retryAfter: nil, body: #"{"error":\#(nest)}"#).listener == .invalidKey)
        }
    }

    @Test("Recognised but invalid encodings fail closed: short \\u, bad percent pairs, empty numeric entities")
    func malformedSyntax() {
        let verifier = SecretVerifier(secrets: [Self.key])
        for text in [#"x \u12 y"#, #"x \u1g2h y"#, "x %G1 y", "x %1G y", "x %4", "x &#x; y", "x &#; y"] {
            #expect(verifier.verifyRecordedText(text) == .exhausted, "\(text)")
        }
        // Text that only looks near an encoding stays readable.
        for text in [#"C:\users\me"#, "50% off", "100%.", "R&D", "%ok"] {
            #expect(verifier.verifyRecordedText(text) == .clean, "\(text)")
        }
    }

    @Test("A spacing mark after a mask still belongs to the masked token, in both sinks")
    func spacingMarkGlue() {
        let text = "provided: sk-" + "proj-***\u{0903}uvwx and more"
        let line = RedactingLogger.safeLine(text)
        #expect(!line.contains("uvwx"), "\(line)")
        let recording = RedactingLogger.safeRecording(.object([JSONMember("m", .string(text))]), secrets: [])
        #expect(!recording.text.contains("uvwx"), "\(recording.text)")
    }

    @Test("A quoted credential value ends at its closing quote, not at an escaped one, in both sinks")
    func escapedQuotes() {
        let cases = [
            #"api_key: "abc\"tailsecret" next"#,
            #"Authorization: Bearer "abc\"tailsecret" next"#,
            #"token='abc\'tailsecret' next"#,
        ]
        for text in cases {
            let line = RedactingLogger.safeLine(text)
            #expect(!line.contains("tailsecret"), "\(line)")
            #expect(line.contains("next"), "\(line)")
            let recording = RedactingLogger.safeRecording(.object([JSONMember("m", .string(text))]), secrets: [])
            #expect(!recording.text.contains("tailsecret"), "\(recording.text)")
        }
    }

    /// CPU seconds for `body` at `size` on this thread, the best of three.
    static func seconds(_ size: Int, _ body: (Int) -> Void) -> Double {
        (0..<3).map { _ in
            let start = ProviderTestSupport.threadCPUSeconds()
            body(size)
            return ProviderTestSupport.threadCPUSeconds() - start
        }.min()!
    }

    static func linear(_ name: String, _ body: @escaping @Sendable (Int) -> Void) async {
        let (small, large) = await ProviderTestSupport.offPool { (seconds(4 * 1024, body), seconds(32 * 1024, body)) }
        print("linearity \(name): 4k \(small) s, 32k \(large) s")
        #expect(large < 3 && large < 32 * max(small, 0.005), "\(name): 4k \(small) s, 32k \(large) s")
    }

    @Test("Scalars that decompose to combining marks, and secrets that do, stay linear")
    func decomposedMarksAreLinear() async {
        // U+FF9E becomes U+3099 (combining class 8) only when decomposed;
        // between acute accents (class 230) the run needs reordering.
        for (name, unit) in [("voiced sound marks between accents", "\u{FF9E}\u{0301}"), ("semi-voiced sound marks", "\u{FF9F}"), ("sara am", "\u{0E33}")] {
            await Self.linear("\(name), verifier") { size in
                _ = SecretVerifier(secrets: [Self.key]).verifyRecordedText("x" + String(repeating: unit, count: size / unit.unicodeScalars.count))
            }
            await Self.linear("\(name), sinks") { size in
                let text = "x" + String(repeating: unit, count: size / unit.unicodeScalars.count)
                _ = RedactingLogger.safeLine(text, secrets: [Self.key])
                _ = RedactingLogger.safeRecording(.object([JSONMember("m", .string(text))]), secrets: [Self.key])
            }
        }
        // Marks of two classes alternating: hashing the key normalises it,
        // and the reordering is the costly step.
        await Self.linear("registering a key with a long mark run") { size in
            _ = SecretVerifier(secrets: ["Qx7Lm2Np" + String(repeating: "\u{0301}\u{0316}", count: size / 2), Self.key])
        }
        await Self.linear("redacting with a key with a long mark run") { size in
            _ = RedactingLogger.redact("x", secrets: ["Qx7Lm2Np" + String(repeating: "\u{0301}\u{0316}", count: size / 2)])
        }
    }

    @Test("A registered secret shorter than a window fails every sink closed instead of matching noise")
    func shortSecretFailsClosed() {
        for secret in ["m", "Zq", "Zq9", "\u{FF3A}q9"] {
            let verifier = SecretVerifier(secrets: [secret, Self.key])
            #expect(verifier.verifyRecordedText("nothing here") == .exhausted, "\(secret)")
            #expect(verifier.verifyAppText("nothing here") == .exhausted, "\(secret)")
            let recording = RedactingLogger.safeRecording(.object([JSONMember("m", .string("nothing here"))]), secrets: [secret])
            #expect(!recording.recorded && FragmentOracle.isPlaceholder(recording.text), "\(secret)")
            #expect(RedactingLogger.safeLine("nothing here", secrets: [secret]) == RedactingLogger.redactedLine, "\(secret)")
        }
    }

    @Test("The oracle reads JSON nested past the verifier's four levels, named entities, and short secrets")
    func oracleReach() {
        var nested = JSONWriter.string(.object([JSONMember("v", .string(Self.key))]))
        for _ in 0..<6 { nested = JSONWriter.string(.object([JSONMember("v", .string(nested))])) }
        let fragments = FragmentOracle.fragments([Self.key])
        #expect(FragmentOracle.leak(inArtifact: nested, fragments: fragments) != nil)
        #expect(FragmentOracle.texts(ofArtifact: nested).contains(Self.key))
        #expect(FragmentOracle.decodings("a&nbsp;b").texts.contains("a\u{00A0}b"))
        let short = FragmentOracle.fragments(["Zq9"])
        #expect(FragmentOracle.leak(inArtifact: #"{"m":"aZq9b"}"#, fragments: short) != nil)
    }

    @Test("The recorder persists no provider string: no message, id, model version, signature or unknown type")
    func recorderPersistsNoProviderString() async throws {
        let directory = ReplayToolTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let success = #"{"id":"resp_providerid77","object":"response","status":"completed","model":"gpt-provider-version-77","output":[{"id":"msg_provider77","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"{\"spans\":[]}","annotations":[],"logprobs":[]}]}],"usage":{"input_tokens":10,"output_tokens":5,"output_tokens_details":{"reasoning_tokens":2},"input_tokens_details":{"cached_tokens":0},"total_tokens":15},"metadata":{"note":"provider-metadata-77"}}"#
        let failure = #"{"error":{"message":"Provider message seventy-seven","type":"provider_type_seventy_seven","param":"provider-param-77","code":"invalid_api_key"}}"#
        let inner = ScriptedHTTPClient([
            .respond(AnalysisHTTPResponse(status: 200, body: Data(success.utf8))),
            .respond(AnalysisHTTPResponse(status: 401, body: Data(failure.utf8))),
        ])
        let recorder = try ReplayToolTests.recorder(inner, directory: directory)
        let request = try ReplayToolTests.generateRequest()
        _ = try? await recorder.send(request, timeoutSeconds: 300, maximumBodyBytes: 1 << 16)
        _ = try? await recorder.send(request, timeoutSeconds: 300, maximumBodyBytes: 1 << 16)
        let texts = try ReplayToolTests.recordedTexts(directory)
        let all = texts.joined(separator: "\n")
        for planted in ["providerid77", "gpt-provider-version-77", "msg_provider77", "provider-metadata-77",
                        "Provider message seventy-seven", "provider_type_seventy_seven", "provider-param-77", "annotations"] {
            #expect(!all.contains(planted), "\(planted) was recorded")
        }
        #expect(all.contains(#"{\"spans\":[]}"#), "the answer text is kept")
        #expect(all.contains("invalid_api_key"), "a known error code is kept")
    }
}
