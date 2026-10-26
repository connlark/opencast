import CryptoKit
import Foundation
@testable import OpenCastAnalysis
@testable import OpenCastAnalysisProviders
import Testing

@Suite("Gemini transport")
struct GeminiAnalysisTransportTests {
    let model = ProviderTestSupport.googleEntry()

    @Test("The generate request is the canonical text, byte for byte, with only the key and content-type headers")
    func exactRequest() async throws {
        let client = ScriptedHTTPClient(status: 200, body: TestSupport.geminiBody("{\"spans\":[]}"))
        let transport = try ProviderTestSupport.googleTransport(client)
        let request = try ProviderTestSupport.adWindowRequest(model: model, timeout: 75)
        let reply = try await transport.send(request)

        #expect(reply == .geminiBody(TestSupport.geminiBody("{\"spans\":[]}")))
        let sent = try #require(client.requests.first)
        #expect(sent.method == "POST")
        #expect(sent.url.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent")
        #expect(sent.headers.map(\.name) == ["content-type", "x-goog-api-key"])
        #expect(sent.header("content-type") == "application/json")
        #expect(sent.header("x-goog-api-key") == ProviderTestKeys.googleText)
        #expect(sent.body == Data(request.payloadText.utf8))
        #expect(client.timeouts == [75])
    }

    @Test("Bundle version headers are added; one naming the key or content type is dropped")
    func versionHeaders() async throws {
        var endpoint = ProviderTestSupport.googleEndpoint
        endpoint.versionHeaders = ["x-goog-api-client": "opencast", "X-Goog-Api-Key": "other", "content-type": "text/plain"]
        let client = ScriptedHTTPClient(status: 200, body: TestSupport.geminiBody("{}"))
        let transport = try GeminiAnalysisTransport(endpoint: endpoint, key: ProviderTestKeys.google, client: client, clock: AnalysisFrozenClock())
        _ = try await transport.send(try ProviderTestSupport.adWindowRequest(model: model))
        let sent = try #require(client.requests.first)
        #expect(sent.headers.map(\.name) == ["content-type", "x-goog-api-key", "x-goog-api-client"])
        #expect(sent.header("x-goog-api-key") == ProviderTestKeys.googleText)
        #expect(sent.header("content-type") == "application/json")
    }

    @Test("An endpoint off the pinned host or with the wrong auth style is refused")
    func pinnedHost() throws {
        for base in ["https://evil.example/v1beta", "http://generativelanguage.googleapis.com/v1beta",
                     "https://generativelanguage.googleapis.com:8443/v1beta", "https://user@generativelanguage.googleapis.com/v1beta"] {
            var endpoint = ProviderTestSupport.googleEndpoint
            endpoint.baseURL = URL(string: base)!
            #expect(throws: AnalysisProviderConfigurationError.unpinnedEndpoint) {
                try GeminiAnalysisTransport(endpoint: endpoint, key: ProviderTestKeys.google)
            }
        }
        #expect(throws: AnalysisProviderConfigurationError.unpinnedEndpoint) {
            try GeminiAnalysisTransport(endpoint: ProviderTestSupport.openAIEndpoint, key: ProviderTestKeys.google)
        }
        var bearer = ProviderTestSupport.googleEndpoint
        bearer.auth = .bearer
        #expect(throws: AnalysisProviderConfigurationError.wrongAuthentication) {
            try GeminiAnalysisTransport(endpoint: bearer, key: ProviderTestKeys.google)
        }
    }

    @Test("A model id that could leave the path is refused before anything is sent")
    func unsafeModelID() async throws {
        for id in ["../evil", "gemini?x=1", "gemini#a", "a/b", "", String(repeating: "a", count: 129), "gemini flash"] {
            var entry = model
            entry.modelID = id
            let client = ScriptedHTTPClient([])
            let log = AnalysisProviderSendLog()
            let transport = try ProviderTestSupport.googleTransport(client, observer: log)
            let result = await ProviderTestSupport.sendResult(transport, try ProviderTestSupport.adWindowRequest(model: entry))
            #expect(result == .failure(.rejected(status: 0)), "\(id)")
            #expect(client.requests.isEmpty)
            #expect(log.sends.first?.failure == .requestRejected)
        }
    }

    @Test("A 2xx body is passed through verbatim and recorded with its finish reason and billed usage")
    func passesBodyThrough() async throws {
        let body = #"{"candidates":[{"content":{"parts":[{"text":"x","thought":true},{"text":"{\"spans\":[]}"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":1200,"cachedContentTokenCount":200,"candidatesTokenCount":40,"thoughtsTokenCount":300,"totalTokenCount":1540},"modelVersion":"gemini-3.8-flash"}"#
        let log = AnalysisProviderSendLog()
        let transport = try ProviderTestSupport.googleTransport(ScriptedHTTPClient(status: 200, body: body), observer: log)
        let reply = try await transport.send(try ProviderTestSupport.adWindowRequest(model: model))
        #expect(reply == .geminiBody(body))
        let send = try #require(log.sends.first)
        #expect(send.finishReason == .stop)
        #expect(send.failure == nil)
        #expect(send.status == 200)
        #expect(send.usage == AnalysisBilledUsage(input: 1200, cached: 200, write: 0, output: 340, reasoning: 300))
    }

    @Test("A body that is not UTF-8 is invalidEncoding whatever the status")
    func invalidEncoding() async throws {
        for status in [200, 400, 503] {
            let response = AnalysisHTTPResponse(status: status, body: Data([0x7B, 0xFF, 0xFE, 0x7D]))
            let log = AnalysisProviderSendLog()
            let transport = try ProviderTestSupport.googleTransport(ScriptedHTTPClient([.respond(response)]), observer: log)
            let result = await ProviderTestSupport.sendResult(transport, try ProviderTestSupport.adWindowRequest(model: model))
            #expect(result == .failure(.invalidEncoding))
            #expect(log.sends.first?.failure == .malformedAnswer)
        }
    }

    @Test("countTokens wraps the canonical payload in generateContentRequest and reads totalTokens")
    func countTokens() async throws {
        let client = ScriptedHTTPClient(status: 200, body: #"{"totalTokens": 4321}"#)
        let transport = try ProviderTestSupport.googleTransport(client)
        let request = try ProviderTestSupport.adWindowRequest(model: model)
        let count = await transport.countTokens(request)
        #expect(count == AnalysisTokenCount(tokens: 4321, isEstimated: false))
        let sent = try #require(client.requests.first)
        #expect(sent.url.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:countTokens")
        let body = try JSONParser.parse(String(decoding: try #require(sent.body), as: UTF8.self))
        guard case .object(var members) = body["generateContentRequest"] else {
            Issue.record("no generateContentRequest")
            return
        }
        #expect(members.first == JSONMember("model", .string("models/gemini-3.8-flash")))
        members.removeFirst()
        #expect(JSONValue.object(members) == request.payload)
        #expect(client.timeouts == [AnalysisProviderLimits.auxiliaryCallTimeoutSeconds])
    }

    @Test("A failed count falls back to bytes / 3, marked estimated")
    func countFallback() async throws {
        let request = try ProviderTestSupport.adWindowRequest(model: model)
        let expected = (request.payloadText.utf8.count + 2) / 3
        for client in [ScriptedHTTPClient(status: 500, body: "{}"), ScriptedHTTPClient([.fail(.timeout)]),
                       ScriptedHTTPClient(status: 200, body: #"{"total": 3}"#)] {
            let count = await (try ProviderTestSupport.googleTransport(client)).countTokens(request)
            #expect(count == AnalysisTokenCount(tokens: expected, isEstimated: true))
        }
    }

    @Test("The key test is countTokens on the entry's model, classified like any other exchange")
    func testKey() async throws {
        let accepted = ScriptedHTTPClient(status: 200, body: #"{"totalTokens": 1}"#)
        #expect(await (try ProviderTestSupport.googleTransport(accepted)).testKey(model: model) == .accepted)
        #expect(accepted.requests.first?.url.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:countTokens")
        let invalid = ScriptedHTTPClient(status: 400, body: #"{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT","details":[{"reason":"API_KEY_INVALID"}]}}"#)
        #expect(await (try ProviderTestSupport.googleTransport(invalid)).testKey(model: model) == .failed(.invalidKey))
        let missing = ScriptedHTTPClient(status: 404, body: #"{"error":{"code":404,"status":"NOT_FOUND"}}"#)
        #expect(await (try ProviderTestSupport.googleTransport(missing)).testKey(model: model) == .failed(.modelUnavailable))
        let offline = ScriptedHTTPClient([.fail(.network)])
        #expect(await (try ProviderTestSupport.googleTransport(offline)).testKey(model: model) == .failed(.unreachable))
    }
}

extension GeminiAnalysisTransportTests {
    static let finishCanary = "FINISH-REASON-CANARY"
    /// Gemini's `FinishReason` values as the API reference listed them on
    /// 2026-10-24 (ai.google.dev/api/generate-content).
    static let documentedFinishReasons = [
        "FINISH_REASON_UNSPECIFIED", "STOP", "MAX_TOKENS", "SAFETY", "RECITATION", "LANGUAGE", "OTHER", "BLOCKLIST",
        "PROHIBITED_CONTENT", "SPII", "MALFORMED_FUNCTION_CALL", "IMAGE_SAFETY", "IMAGE_PROHIBITED_CONTENT", "IMAGE_OTHER",
        "NO_IMAGE", "IMAGE_RECITATION", "UNEXPECTED_TOOL_CALL", "TOO_MANY_TOOL_CALLS", "MISSING_THOUGHT_SIGNATURE",
        "MALFORMED_RESPONSE", "ESCALATION", "PUP_LIMITED_DISABLED", "CONTINUATION",
    ]

    @Test("An undocumented finish reason never reaches a recovered Chapters response, its warnings or its reflection")
    func recoveredChaptersCarryNoProviderText() async throws {
        let reason = "\(Self.finishCanary)-\(ProviderTestKeys.googleText)"
        let failed = TestSupport.geminiBody(AnalysisRunnerTests.validChapters, finish: reason)
        let recovered = TestSupport.geminiBody(AnalysisRunnerTests.validChapters)
        let client = ScriptedHTTPClient([
            .respond(AnalysisHTTPResponse(status: 200, body: Data(failed.utf8))),
            .respond(AnalysisHTTPResponse(status: 200, body: Data(recovered.utf8))),
        ])
        var entry = AnalysisModelEntry.serviceChaptersSummary
        entry.modelID = model.modelID
        let outcome = await AnalysisRunner(transport: try ProviderTestSupport.googleTransport(client), clock: AnalysisFrozenClock())
            .generateChapters(AnalysisRunnerTests.chapters, policy: ChaptersSummaryAnalysisPolicy.service.with(model: entry))
        guard case .chaptersSummary(let response) = outcome else {
            Issue.record("the retry did not recover: \(outcome)")
            return
        }
        #expect(client.requests.count == 2)
        #expect(response.warnings.contains("gemini_finish_reason:MALFORMED_RESPONSE"), "\(response.warnings)")
        for text in [JSONWriter.string(response.jsonValue), response.warnings.joined(separator: " "),
                     String(describing: outcome), String(reflecting: outcome), RedactionTests.dump(outcome)] {
            #expect(!text.contains(Self.finishCanary), "\(text)")
            #expect(!ProviderTestKeys.leaks(in: text), "\(text)")
        }
    }

    @Test("Bodies whose finish reasons are all documented reach the pipeline byte for byte")
    func documentedFinishReasonsPassUnchanged() throws {
        var bodies = [try RecordedExchangeTests.recorded("gemini-carousel-success.json").response.body]
        for item in try ProviderTestSupport.providerFixture("answer-cases.json")["cases"]?.arrayValue ?? []
        where item["provider"]?.stringValue == "google" {
            bodies.append(Data(try #require(item["body"]?.stringValue).utf8))
        }
        bodies.append(Data(TestSupport.geminiBody(AnalysisRunnerTests.validChapters).utf8))
        for reason in Self.documentedFinishReasons {
            bodies.append(Data(TestSupport.geminiBody("{\"spans\":[]}", finish: reason).utf8))
        }
        bodies.append(Data(#"{"candidates":[{"content":{"parts":[{"text":"x"}]}}],"usageMetadata":{"promptTokenCount":1}}"#.utf8))
        #expect(bodies.count > 25)
        for body in bodies {
            let text = String(decoding: body, as: UTF8.self)
            #expect(GeminiAnalysisTransport.interpret(text).reply == .geminiBody(text))
        }
    }

    @Test("The documented vocabulary is Gemini's reference list, and records map anything else to MALFORMED_RESPONSE")
    func vocabulary() {
        #expect(AnalysisFinishReason.geminiVocabulary == Set(Self.documentedFinishReasons))
        for reason in Self.documentedFinishReasons {
            #expect(AnalysisFinishReason.gemini(reason)?.rawValue == reason)
        }
        #expect(AnalysisFinishReason.gemini("REFUSAL") == .malformedResponse)
        #expect(AnalysisFinishReason.gemini("stop") == .malformedResponse)
        #expect(AnalysisFinishReason.gemini(nil) == nil)
    }

    @Test("Only the undocumented finish reasons are replaced; everything else in the body stays")
    func undocumentedFinishReasonsReplaced() throws {
        let body = #"{"candidates":[{"content":{"parts":[{"text":"keep me"}],"role":"model"},"finishReason":"NOT_A_REASON"},{"content":{"parts":[{"text":"second"}]},"finishReason":"SAFETY"}],"usageMetadata":{"promptTokenCount":7,"candidatesTokenCount":3,"totalTokenCount":10},"modelVersion":"gemini-3.8-flash"}"#
        let interpreted = GeminiAnalysisTransport.interpret(body)
        guard case .geminiBody(let forwarded) = interpreted.reply else {
            Issue.record("not a Gemini body")
            return
        }
        let expected = body.replacing("NOT_A_REASON", with: "MALFORMED_RESPONSE")
        #expect(try JSONParser.parse(forwarded) == JSONParser.parse(expected))
        #expect(!forwarded.contains("NOT_A_REASON"))
    }
}
