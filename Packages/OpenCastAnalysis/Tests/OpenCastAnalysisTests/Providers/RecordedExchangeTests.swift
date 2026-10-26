import Foundation
@testable import OpenCastAnalysis
@testable import OpenCastAnalysisProviders
import Testing

/// The live smokes' exchanges, kept as the recorder's structured fields and
/// replayed with the provider body rebuilt from the recorded answer text,
/// finish reason and usage: each transport builds exactly the request that
/// was sent and turns the rebuilt answer into the same result.
@Suite("Recorded provider exchanges")
struct RecordedExchangeTests {
    struct Recorded {
        var url: String
        var headerNames: [String]
        var body: JSONValue
        var response: AnalysisHTTPResponse
        var spans: [[Int64]]
        var usage: JSONValue
    }

    static func recorded(_ name: String) throws -> Recorded {
        let fixture = try ProviderTestSupport.providerFixture(name)
        let request = try #require(fixture["request"])
        let response = try #require(fixture["response"])
        let spans = try (fixture["expect"]?["spans"]?.arrayValue ?? []).map { pair in
            try (pair.arrayValue ?? []).map { try #require(ProviderJSON.count($0)).asInt64 }
        }
        return Recorded(
            url: try #require(request["url"]?.stringValue),
            headerNames: (request["header_names"]?.arrayValue ?? []).compactMap(\.stringValue),
            body: try #require(request["body"]),
            response: AnalysisHTTPResponse(
                status: Int(try #require(ProviderJSON.count(response["status"]))),
                body: Data(try #require(response["body"]?.stringValue).utf8)
            ),
            spans: spans,
            usage: try #require(fixture["expect"]?["usage"])
        )
    }

    func replay(_ recorded: Recorded, transport: any AnalysisProviderTransport, model: AnalysisModelEntry) async throws {
        let outcome = await AnalysisRunner(transport: transport, clock: AnalysisFrozenClock())
            .detectAds(try ProviderTestSupport.carouselRequest, policy: AdDetectionAnalysisPolicy.service.with(model: model))
        guard case .adDetection(let response) = outcome else {
            Issue.record("replay failed: \(outcome)")
            return
        }
        #expect(response.spans.map { [$0.startSegmentID, $0.endSegmentID] } == recorded.spans)
        #expect(response.usage?.jsonValue == recorded.usage)
        #expect(response.model == model.modelID)
    }

    @Test("Gemini: the recorded request is the canonical text, and the recorded answer replays to the same spans")
    func gemini() async throws {
        let recorded = try Self.recorded("gemini-carousel-success.json")
        let model = ProviderTestSupport.googleEntry()
        let client = ScriptedHTTPClient([.respond(recorded.response)])
        let transport = try ProviderTestSupport.googleTransport(client)
        let request = try #require(transport.generateRequest(try ProviderTestSupport.adWindowRequest(model: model)))
        #expect(request.url.absoluteString == recorded.url)
        #expect(request.headers.map(\.name) == recorded.headerNames)
        #expect(String(decoding: try #require(request.body), as: UTF8.self) == recorded.body.stringValue)
        try await replay(recorded, transport: transport, model: model)
        #expect(client.requests.first?.body == request.body)
    }

    @Test("OpenAI: the recorded request is the mapped Responses body, and the recorded answer replays to the same spans")
    func openAI() async throws {
        let recorded = try Self.recorded("openai-carousel-success.json")
        let model = ProviderTestSupport.openAIEntry()
        let client = ScriptedHTTPClient([.respond(recorded.response)])
        let transport = try ProviderTestSupport.openAITransport(client)
        let request = try #require(transport.generateRequest(try ProviderTestSupport.adWindowRequest(model: model)))
        #expect(request.url.absoluteString == recorded.url)
        #expect(request.headers.map(\.name) == recorded.headerNames)
        #expect(try JSONParser.parse(String(decoding: try #require(request.body), as: UTF8.self)) == recorded.body)
        try await replay(recorded, transport: transport, model: model)
    }
}

extension UInt64 {
    var asInt64: Int64 { Int64(clamping: self) }
}
