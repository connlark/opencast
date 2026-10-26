import CryptoKit
import Foundation
@testable import OpenCastAnalysis
@testable import OpenCastAnalysisProviders
import Testing

@Suite("OpenAI transport")
struct OpenAIAnalysisTransportTests {
    let model = ProviderTestSupport.openAIEntry()

    @Test("The Responses body equals the evaluation harness adapter's for the carousel window")
    func harnessEquivalence() throws {
        let fixture = try ProviderTestSupport.providerFixture("openai-responses-carousel-window.json")
        let request = try ProviderTestSupport.adWindowRequest(model: model)
        let digest = SHA256.hash(data: Data(request.payloadText.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(digest == fixture["canonical_payload_sha256"]?.stringValue)
        let body = try #require(OpenAIResponsesMapping.body(for: request))
        #expect(body.sortedKeys() == (try #require(fixture["wire"])).sortedKeys())
    }

    @Test("The request goes to /v1/responses with bearer auth and JSON content")
    func exactRequest() async throws {
        let client = ScriptedHTTPClient(status: 200, body: Self.completed(text: "{\"spans\":[]}"))
        let transport = try ProviderTestSupport.openAITransport(client)
        let request = try ProviderTestSupport.adWindowRequest(model: model, timeout: 90)
        _ = try await transport.send(request)
        let sent = try #require(client.requests.first)
        #expect(sent.method == "POST")
        #expect(sent.url.absoluteString == "https://api.openai.com/v1/responses")
        #expect(sent.headers.map(\.name) == ["authorization", "content-type"])
        #expect(sent.header("authorization") == "Bearer \(ProviderTestKeys.openAIText)")
        let body = try JSONParser.parse(String(decoding: try #require(sent.body), as: UTF8.self))
        #expect(body == OpenAIResponsesMapping.body(for: request))
        #expect(client.timeouts == [90])
    }

    @Test("Chapters maps to one user turn, a closed strict schema, no sampling settings")
    func chaptersMapping() throws {
        let settings = AnalysisPolicyBundle.baked.features.chaptersSummary
        let payload = ChaptersCanonicalPayload.payload(
            try Self.chaptersRequest(),
            policy: settings,
            maxOutputTokens: 32_768,
            thinking: "high"
        )
        var entry = model
        entry.maxOutputTokens = 32_768
        let request = AnalysisProviderRequest(
            feature: .chaptersSummary, purpose: .chapters(attempt: 1), model: entry, payload: payload,
            payloadText: JSONWriter.string(payload), thinking: "high", timeoutSeconds: 300, sendIndex: 0
        )
        let body = try #require(OpenAIResponsesMapping.body(for: request))
        #expect(body["model"] == .string("gpt-6.1-sol"))
        #expect(body["reasoning"] == .object(["effort": .string("high")]))
        #expect(body["max_output_tokens"] == .integer(32_768))
        #expect(body["instructions"] == nil)
        #expect(body["temperature"] == nil && body["top_p"] == nil)
        let input = try #require(body["input"]?.arrayValue)
        #expect(input.count == 1)
        #expect(input[0]["content"]?.arrayValue?.first?["text"] == payload["contents"]?.arrayValue?.first?["parts"]?.arrayValue?.first?["text"])
        let format = try #require(body["text"]?["format"])
        #expect(format["name"] == .string("podcast_chapters_summary"))
        #expect(format["strict"] == .bool(true))
        let schema = try #require(format["schema"])
        #expect(Self.objectNodes(schema).allSatisfy { $0["additionalProperties"] == .bool(false) })
        #expect(Self.objectNodes(schema).count == 4)
    }

    @Test("Later turns map to plain-text messages, model turns as assistant; no thinking omits reasoning")
    func turnsAndNoThinking() throws {
        var request = try ProviderTestSupport.adWindowRequest(model: model)
        guard case .object(var members) = request.payload,
              let index = members.firstIndex(where: { $0.key == "contents" }),
              case .array(var contents) = members[index].value
        else {
            Issue.record("unexpected payload")
            return
        }
        contents.append(.object(["parts": .array([.object(["text": .string("previous")])]), "role": .string("model")]))
        contents.append(.object(["parts": .array([.object(["text": .string("fix it")])]), "role": .string("user")]))
        members[index].value = .array(contents)
        request.payload = .object(members)
        request.thinking = nil
        let body = try #require(OpenAIResponsesMapping.body(for: request))
        let input = try #require(body["input"]?.arrayValue)
        #expect(input.dropFirst().map { $0["role"] } == [.string("assistant"), .string("user")])
        #expect(input.dropFirst().map { $0["content"] } == [.string("previous"), .string("fix it")])
        #expect(body["reasoning"] == nil)
    }

    @Test("Answers: completed is STOP with the output text; truncation is MAX_TOKENS; other endings map to the closed set")
    func answers() {
        let done = OpenAIResponsesMapping.answer(fromBody: Self.completed(text: "{\"spans\":[]}"))
        #expect(done.answer.texts == ["{\"spans\":[]}"])
        #expect(done.answer.finishReason == "STOP")
        #expect(done.usage == AnalysisBilledUsage(input: 1000, cached: 100, write: 0, output: 300, reasoning: 200))
        #expect(done.answer.usage == AnalysisUsage(promptTokenCount: 1000, candidatesTokenCount: 100, thoughtsTokenCount: 200, totalTokenCount: 1300))

        let truncated = OpenAIResponsesMapping.answer(fromBody: Self.response(status: "incomplete", incomplete: "max_output_tokens", text: "{\"spans\":[{\"kind\""))
        #expect(truncated.answer.texts.isEmpty)
        #expect(truncated.answer.finishReason == "MAX_TOKENS")
        let filtered = OpenAIResponsesMapping.answer(fromBody: Self.response(status: "incomplete", incomplete: "content_filter", text: nil))
        #expect(filtered.answer.finishReason == "CONTENT_FILTER")
        let failed = OpenAIResponsesMapping.answer(fromBody: Self.response(status: "failed", incomplete: nil, text: nil))
        #expect(failed.answer.finishReason == "FAILED")
        let other = OpenAIResponsesMapping.answer(fromBody: Self.response(status: "incomplete", incomplete: "some_new_reason", text: nil))
        #expect(other.answer.finishReason == "INCOMPLETE")
        let unknown = OpenAIResponsesMapping.answer(fromBody: Self.response(status: "some_new_status", incomplete: nil, text: nil))
        #expect(unknown.answer.finishReason == "MALFORMED_RESPONSE")
        for malformed in ["not json", "[]", #"{"output":[]}"#] {
            let answer = OpenAIResponsesMapping.answer(fromBody: malformed)
            #expect(answer.answer == AnalysisProviderAnswer(texts: [], finishReason: "MALFORMED_RESPONSE", usage: nil))
        }
    }

    @Test("A completed response with an unfinished message or a refusal is not an answer")
    func inconsistentMessages() async throws {
        let mixed = JSONWriter.string(.object([
            "object": .string("response"), "status": .string("completed"), "error": .null, "incomplete_details": .null,
            "output": .array([
                .object(["type": .string("message"), "status": .string("completed"),
                         "content": .array([.object(["type": .string("output_text"), "text": .string("{\"spans\":[]}")])])]),
                .object(["type": .string("message"), "status": .string("incomplete"),
                         "content": .array([.object(["type": .string("output_text"), "text": .string("{\"spans\":[{")])])]),
            ]),
            "usage": .object(["input_tokens": .integer(10), "output_tokens": .integer(5)]),
        ]))
        #expect(OpenAIResponsesMapping.answer(fromBody: mixed).answer == AnalysisProviderAnswer(
            texts: [], finishReason: "INCOMPLETE",
            usage: AnalysisUsage(promptTokenCount: 10, candidatesTokenCount: 5, thoughtsTokenCount: 0, totalTokenCount: 15)
        ))
        let refusal = JSONWriter.string(.object([
            "object": .string("response"), "status": .string("completed"), "error": .null, "incomplete_details": .null,
            "output": .array([
                .object(["type": .string("message"), "status": .string("completed"),
                         "content": .array([
                             .object(["type": .string("output_text"), "text": .string("{\"spans\":[]}")]),
                             .object(["type": .string("refusal"), "refusal": .string("no")]),
                         ])]),
            ]),
        ]))
        #expect(OpenAIResponsesMapping.answer(fromBody: refusal).answer.finishReason == "REFUSAL")
        #expect(OpenAIResponsesMapping.answer(fromBody: refusal).answer.texts.isEmpty)
        for body in [mixed, refusal] {
            let step = ScriptedHTTPClient.Step.respond(AnalysisHTTPResponse(status: 200, body: Data(body.utf8)))
            let runner = AnalysisRunner(transport: try ProviderTestSupport.openAITransport(ScriptedHTTPClient(Array(repeating: step, count: 5))), clock: AnalysisFrozenClock())
            let outcome = await runner.detectAds(try ProviderTestSupport.carouselRequest, policy: AdDetectionAnalysisPolicy.service.with(model: model))
            guard case .failed = outcome else {
                Issue.record("accepted an inconsistent answer")
                continue
            }
        }
    }

    @Test("Usage normalises as the archived OpenAI runs were replayed; bad counts drop usage")
    func usage() {
        let reasoningHeavy = AnalysisBilledUsage(input: 10, cached: 0, write: 0, output: 5, reasoning: 8)
        #expect(OpenAIResponsesMapping.neutralUsage(reasoningHeavy)
            == AnalysisUsage(promptTokenCount: 10, candidatesTokenCount: 0, thoughtsTokenCount: 8, totalTokenCount: 18))
        #expect(OpenAIResponsesMapping.billedUsage(try? JSONParser.parse(#"{"input_tokens":5,"output_tokens":2,"output_tokens_details":null}"#))
            == AnalysisBilledUsage(input: 5, cached: 0, write: 0, output: 2, reasoning: 0))
        #expect(OpenAIResponsesMapping.billedUsage(try? JSONParser.parse(#"{"input_tokens":5}"#)) == nil)
        #expect(OpenAIResponsesMapping.billedUsage(try? JSONParser.parse(#"{"input_tokens":5,"output_tokens":-1}"#)) == nil)
        #expect(OpenAIResponsesMapping.billedUsage(try? JSONParser.parse(#"{"input_tokens":5,"output_tokens":2,"output_tokens_details":{"reasoning_tokens":"x"}}"#)) == nil)
    }

    @Test("countTokens posts the counted members to /responses/input_tokens; failure estimates")
    func countTokens() async throws {
        let request = try ProviderTestSupport.adWindowRequest(model: model)
        let client = ScriptedHTTPClient(status: 200, body: #"{"object":"response.input_tokens","input_tokens":2048}"#)
        let count = await (try ProviderTestSupport.openAITransport(client)).countTokens(request)
        #expect(count == AnalysisTokenCount(tokens: 2048, isEstimated: false))
        let sent = try #require(client.requests.first)
        #expect(sent.url.absoluteString == "https://api.openai.com/v1/responses/input_tokens")
        let body = try JSONParser.parse(String(decoding: try #require(sent.body), as: UTF8.self))
        #expect(Set(body.objectMembers?.map(\.key) ?? []) == ["model", "input", "instructions", "text", "tools"])

        let wire = try #require(OpenAIResponsesMapping.body(for: request))
        let fallback = await (try ProviderTestSupport.openAITransport(ScriptedHTTPClient(status: 401, body: "{}"))).countTokens(request)
        #expect(fallback == AnalysisTokenCount(tokens: (JSONWriter.byteCount(wire) + 2) / 3, isEstimated: true))
    }

    @Test("The key test is GET /v1/models with only the bearer header")
    func testKey() async throws {
        let client = ScriptedHTTPClient(status: 200, body: #"{"object":"list","data":[]}"#)
        #expect(await (try ProviderTestSupport.openAITransport(client)).testKey(model: model) == .accepted)
        let sent = try #require(client.requests.first)
        #expect(sent.method == "GET")
        #expect(sent.url.absoluteString == "https://api.openai.com/v1/models")
        #expect(sent.headers.map(\.name) == ["authorization"])
        #expect(sent.body == nil)
        let invalid = ScriptedHTTPClient(status: 401, body: #"{"error":{"code":"invalid_api_key"}}"#)
        #expect(await (try ProviderTestSupport.openAITransport(invalid)).testKey(model: model) == .failed(.invalidKey))
    }

    static func chaptersRequest() throws -> TranscriptAnalysisRequest {
        let text = try TestSupport.repositoryText("Server/AdAnalysisWorker/eval/fixtures/promo-carousel.json")
        return try TranscriptAnalysisRequest(json: try JSONParser.parse(text))
    }

    static func objectNodes(_ value: JSONValue) -> [JSONValue] {
        switch value {
        case .object(let members):
            let own = members.contains { $0.key == "type" && $0.value == .string("object") } ? [value] : []
            return own + members.flatMap { objectNodes($0.value) }
        case .array(let values):
            return values.flatMap(objectNodes)
        default:
            return []
        }
    }

    static func completed(text: String) -> String {
        response(status: "completed", incomplete: nil, text: text)
    }

    static func response(status: String, incomplete: String?, text: String?) -> String {
        var output: [JSONValue] = [
            .object(["type": .string("reasoning"), "id": .string("rs_1"), "summary": .array([])]),
        ]
        if let text {
            output.append(.object([
                "type": .string("message"), "id": .string("msg_1"),
                "status": .string(status == "completed" ? "completed" : "incomplete"), "role": .string("assistant"),
                "content": .array([.object(["type": .string("output_text"), "text": .string(text), "annotations": .array([])])]),
            ]))
        }
        return JSONWriter.string(.object([
            "id": .string("resp_1"), "object": .string("response"), "status": .string(status),
            "error": .null,
            "incomplete_details": incomplete.map { .object(["reason": .string($0)]) } ?? .null,
            "output": .array(output),
            "usage": .object([
                "input_tokens": .integer(1000),
                "input_tokens_details": .object(["cached_tokens": .integer(100)]),
                "output_tokens": .integer(300),
                "output_tokens_details": .object(["reasoning_tokens": .integer(200)]),
                "total_tokens": .integer(1300),
            ]),
        ]))
    }
}

extension OpenAIAnalysisTransportTests {
    /// The recorded carousel response with its `output` items transformed.
    static func recordedResponse(output transform: ([JSONValue]) -> [JSONValue]) throws -> String {
        let recorded = try RecordedExchangeTests.recorded("openai-carousel-success.json")
        guard case .object(let members) = try JSONParser.parse(String(decoding: recorded.response.body, as: UTF8.self)) else {
            throw StrictDecodingError("the recorded response is not an object")
        }
        return JSONWriter.string(.object(members.map { member in
            guard member.key == "output", case .array(let items) = member.value else { return member }
            return JSONMember(member.key, .array(transform(items)))
        }))
    }

    @Test("Every output item must have finished and every message must hold an array of parts")
    func wholeEnvelopeValidated() async throws {
        let model = ProviderTestSupport.openAIEntry()
        #expect(OpenAIResponsesMapping.answer(fromBody: try Self.recordedResponse { $0 }).answer.finishReason == "STOP")
        let message = { (content: JSONValue) -> JSONValue in
            .object(["type": .string("message"), "id": .string("msg_x"), "status": .string("completed"),
                     "role": .string("assistant"), "content": content])
        }
        let variants: [(String, ([JSONValue]) -> [JSONValue])] = [
            ("an incomplete reasoning item", {
                $0 + [.object(["type": .string("reasoning"), "id": .string("rs_x"), "status": .string("incomplete"), "summary": .array([])])]
            }),
            ("an unfinished item of another type", {
                $0 + [.object(["type": .string("function_call"), "id": .string("fc_x"), "status": .string("in_progress")])]
            }),
            ("message content that is not an array", { $0 + [message(.string("{\"spans\":[]}"))] }),
            ("a message part that is not an object", { $0 + [message(.array([.string("{\"spans\":[]}")]))] }),
            ("an item that is not an object", { $0 + [.string("message")] }),
        ]
        var bodies = try variants.map { ($0.0, try Self.recordedResponse(output: $0.1)) }
        let recorded = try RecordedExchangeTests.recorded("openai-carousel-success.json")
        let text = String(decoding: recorded.response.body, as: UTF8.self)
        bodies.append(("output that is not an array", text.replacing(#""output":["#, with: #""output":"x","unused":["#)))
        for (name, body) in bodies {
            let answer = OpenAIResponsesMapping.answer(fromBody: body).answer
            #expect(answer.finishReason != "STOP", "\(name)")
            #expect(answer.texts.isEmpty, "\(name)")
            let step = ScriptedHTTPClient.Step.respond(AnalysisHTTPResponse(status: 200, body: Data(body.utf8)))
            let runner = AnalysisRunner(
                transport: try ProviderTestSupport.openAITransport(ScriptedHTTPClient(Array(repeating: step, count: 5))),
                clock: AnalysisFrozenClock()
            )
            let outcome = await runner.detectAds(try ProviderTestSupport.carouselRequest, policy: AdDetectionAnalysisPolicy.service.with(model: model))
            guard case .failed = outcome else {
                Issue.record("\(name): the run published \(outcome)")
                continue
            }
        }
    }
}
