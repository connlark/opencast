import Foundation
@testable import OpenCastAnalysis
@testable import OpenCastAnalysisProviders
import Testing

/// Gemini 429s read from their structured quota details on the device: a
/// per-minute limit is paced, a per-day limit is final and named as such,
/// and every other shape keeps the services' classification.
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

    @Test("A per-minute RESOURCE_EXHAUSTED with Retry-After 20 is paced, not a hard quota")
    func perMinuteWithHeaderIsPaced() {
        let body = #"{"error":{"code":429,"message":"You exceeded your current quota, please check your plan and billing details.","status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaMetric":"generativelanguage.googleapis.com/generate_content_free_tier_requests","quotaId":"GenerateRequestsPerMinutePerProjectPerModel-FreeTier","quotaValue":"15"}]}]}}"#
        let classified = GeminiProviderErrors.classify(status: 429, retryAfter: "20", body: body)
        #expect(classified.transport == .retryable(status: 429, retryAfterSeconds: 20))
        #expect(classified.listener == .rateLimited)
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

    @Test("The services' classifier is unchanged: every constructed 429 still reads as it did")
    func sharedClassifierUnchanged() throws {
        for item in try Self.cases() {
            guard case .respond(let response) = item.step else { continue }
            let text = String(decoding: response.body, as: UTF8.self)
            let services = GeminiErrorClassifier.error(status: 429, retryAfter: response.retryAfter, body: text)
            // The services read only the envelope's status and message.
            let error = ProviderJSON.parse(text)?["error"]
            let message = ProviderJSON.lowercasedASCII(error?["message"]?.stringValue ?? "")
            let hardQuota = error?["status"]?.stringValue == "RESOURCE_EXHAUSTED"
                && ["quota", "billing", "prepay", "credit"].contains { message.contains($0) }
            #expect(services == (hardQuota ? .quotaExhausted : .retryable(status: 429, retryAfterSeconds: response.retryAfter.flatMap(GeminiErrorClassifier.retryAfterSeconds))), "\(item.name)")
        }
    }
}
