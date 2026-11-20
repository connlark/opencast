import Foundation
@testable import OpenCastAnalysis
@testable import OpenCastAnalysisProviders
import Testing

@Suite("Gemini quota details")
struct GeminiQuotaDetailsTests {
    static func cases() throws -> [ProviderErrorTableTests.Case] {
        let fixture = try ProviderTestSupport.providerFixture("gemini-quota-cases.json")
        return try (fixture["cases"]?.arrayValue ?? []).map { item in
            let body = try #require(item["body"]?.stringValue)
            let expect = try #require(item["expect"])
            let listener = expect["listener"]?.stringValue ?? ""
            return ProviderErrorTableTests.Case(
                name: try #require(item["name"]?.stringValue),
                provider: .google,
                step: .respond(AnalysisHTTPResponse(status: 429, retryAfter: item["retry_after"]?.stringValue, body: Data(body.utf8))),
                transport: try ProviderErrorTableTests.transportError(try #require(expect["transport"]?.stringValue)),
                listener: try #require(AnalysisProviderFailure(rawValue: listener), "unknown listener case \(listener)")
            )
        }
    }

    @Test("Each constructed 429 maps to its pipeline error and listener case")
    func classification() async throws {
        let cases = try Self.cases()
        #expect(cases.count >= 20)
        for item in cases {
            guard case .respond(let response) = item.step else { continue }
            let classified = GeminiProviderErrors.classify(status: 429, retryAfter: response.retryAfter, body: String(decoding: response.body, as: UTF8.self))
            #expect(classified.transport == item.transport, "\(item.name)")
            #expect(classified.listener == item.listener, "\(item.name)")
            let log = AnalysisProviderSendLog()
            let transport = try ProviderTestSupport.googleTransport(ScriptedHTTPClient([item.step]), observer: log)
            let result = await ProviderTestSupport.sendResult(transport, try ProviderTestSupport.adWindowRequest(model: ProviderTestSupport.googleEntry()))
            #expect(result == .failure(item.transport), "\(item.name)")
            #expect(log.sends.map(\.failure) == [item.listener], "\(item.name)")
        }
    }
}
