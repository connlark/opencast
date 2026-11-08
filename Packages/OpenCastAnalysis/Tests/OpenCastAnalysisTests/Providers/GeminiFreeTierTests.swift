import Foundation
@testable import OpenCastAnalysis
@testable import OpenCastAnalysisProviders
import Testing

/// How the app hears Google say a key is on its free tier: the reader, kept
/// apart from the interval rules, and the tier check built on it.
@Suite("Gemini free tier")
struct GeminiFreeTierTests {
    struct QuotaCase {
        var name: String
        var retryAfter: String?
        var body: String
        var namesFreeTier: Bool
    }

    static func quotaCases() throws -> [QuotaCase] {
        let fixture = try ProviderTestSupport.providerFixture("gemini-quota-cases.json")
        return try (fixture["cases"]?.arrayValue ?? []).map { item in
            let name = try #require(item["name"]?.stringValue)
            let expected = try #require(item["expect"]?["free_tier"], "\(name) states no free_tier")
            return QuotaCase(
                name: name,
                retryAfter: item["retry_after"]?.stringValue,
                body: try #require(item["body"]?.stringValue),
                namesFreeTier: expected == .bool(true)
            )
        }
    }

    private static func body(violation: String) -> String {
        #"{"error":{"code":429,"message":"quota","status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[\#(violation)]}]}}"#
    }

    // MARK: The reader

    @Test("The reader answers every case in the quota fixture as the fixture says")
    func everyQuotaCase() throws {
        let cases = try Self.quotaCases()
        #expect(cases.count == 63)
        #expect(cases.count { !$0.namesFreeTier } == 10)
        for item in cases {
            #expect(GeminiProviderErrors.namesFreeTier(status: 429, body: item.body) == item.namesFreeTier, "\(item.name)")
        }
    }

    @Test("The four live refusals read as free tier, though the interval reader leaves them alone")
    func liveRefusals() throws {
        let live = try Self.quotaCases().filter { $0.name.hasPrefix("live-") }
        #expect(live.count == 4)
        for item in live {
            #expect(GeminiProviderErrors.namesFreeTier(status: 429, body: item.body), "\(item.name)")
            #expect(GeminiProviderErrors.QuotaDetails(item.body) == nil, "\(item.name)")
            let classified = GeminiProviderErrors.classify(status: 429, retryAfter: nil, body: item.body)
            #expect(classified.freeTier, "\(item.name)")
            #expect(classified.listener == .billingOrQuota, "\(item.name)")
        }
    }

    @Test("A metric alone or an id alone names the free tier; neither is not enough")
    func metricOrIDAlone() {
        let metric = #"{"quotaMetric":"generativelanguage.googleapis.com/generate_content_free_tier_requests"}"#
        let id = #"{"quotaId":"GenerateRequestsPerDayPerProjectPerModel-FreeTier"}"#
        let paid = #"{"quotaMetric":"generativelanguage.googleapis.com/generate_content_requests","quotaId":"GenerateRequestsPerMinutePerProjectPerModel"}"#

        #expect(GeminiProviderErrors.namesFreeTier(status: 429, body: Self.body(violation: metric)))
        #expect(GeminiProviderErrors.namesFreeTier(status: 429, body: Self.body(violation: id)))
        #expect(!GeminiProviderErrors.namesFreeTier(status: 429, body: Self.body(violation: paid)))
        #expect(GeminiProviderErrors.namesFreeTier(status: 429, body: Self.body(violation: "\(paid),\(id)")))
    }

    @Test("Neither an unreadable interval nor a zero allocation stops the reader")
    func noIntervalAndZeroAllocation() {
        let noInterval = #"{"quotaId":"GenerateRequests-FreeTier"}"#
        let zero = #"{"quotaId":"GenerateRequestsPerDayPerProjectPerModel-FreeTier","quotaValue":"0"}"#

        #expect(GeminiProviderErrors.QuotaDetails(Self.body(violation: noInterval)) == nil)
        #expect(GeminiProviderErrors.namesFreeTier(status: 429, body: Self.body(violation: noInterval)))
        #expect(GeminiProviderErrors.QuotaDetails(Self.body(violation: zero)) == nil)
        #expect(GeminiProviderErrors.namesFreeTier(status: 429, body: Self.body(violation: zero)))
    }

    private static let quotaFailureType = "type.googleapis.com/google.rpc.QuotaFailure"

    private static func body(details: [String]) -> String {
        #"{"error":{"code":429,"message":"quota","status":"RESOURCE_EXHAUSTED","details":[\#(details.joined(separator: ","))]}}"#
    }

    @Test("An empty sibling QuotaFailure does not refuse a marked violation, in either order")
    func emptySiblingQuotaFailure() {
        let marked = #"{"@type":"\#(Self.quotaFailureType)","violations":[{"quotaId":"GenerateRequests-FreeTier"}]}"#
        let empty = #"{"@type":"\#(Self.quotaFailureType)","violations":[]}"#

        #expect(GeminiProviderErrors.namesFreeTier(status: 429, body: Self.body(details: [marked, empty])))
        #expect(GeminiProviderErrors.namesFreeTier(status: 429, body: Self.body(details: [empty, marked])))
    }

    @Test("A lone empty QuotaFailure names nothing, and a QuotaFailure with no list stays unreadable")
    func emptyQuotaFailureAlone() {
        let marked = #"{"@type":"\#(Self.quotaFailureType)","violations":[{"quotaId":"GenerateRequests-FreeTier"}]}"#
        let empty = #"{"@type":"\#(Self.quotaFailureType)","violations":[]}"#
        let noList = #"{"@type":"\#(Self.quotaFailureType)"}"#

        #expect(!GeminiProviderErrors.namesFreeTier(status: 429, body: Self.body(details: [empty])))
        #expect(!GeminiProviderErrors.namesFreeTier(status: 429, body: Self.body(details: [marked, noList])))
        #expect(GeminiProviderErrors.QuotaDetails(Self.body(details: [empty])) == nil)
    }

    @Test(
        "An unreadable envelope is not free tier",
        arguments: [
            "",
            "not json",
            "[]",
            #"{"error":"RESOURCE_EXHAUSTED FreeTier"}"#,
            #"{"error":{"status":"RESOURCE_EXHAUSTED"}}"#,
            #"{"error":{"status":"RESOURCE_EXHAUSTED","details":"-FreeTier"}}"#,
            #"{"error":{"status":"UNAVAILABLE","details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaId":"X-FreeTier"}]}]}}"#,
            #"{"error":{"status":"RESOURCE_EXHAUSTED","message":"free_tier -FreeTier","details":[]}}"#,
        ]
    )
    func unreadableEnvelope(body: String) {
        #expect(!GeminiProviderErrors.namesFreeTier(status: 429, body: body))
    }

    @Test("Only a 429 can name the free tier", arguments: [200, 400, 403, 404, 500, 503])
    func onlyA429(status: Int) throws {
        let body = try #require(try Self.quotaCases().first { $0.name.hasPrefix("live-") }).body
        #expect(!GeminiProviderErrors.namesFreeTier(status: status, body: body))
    }

    // MARK: Classification

    @Test("Every quota case carries its reading without the flag, and the classifier's answer is untouched")
    func classifyWithoutTheFlag() throws {
        let expected = Dictionary(uniqueKeysWithValues: try GeminiQuotaDetailsTests.cases().map { ($0.name, $0) })
        for item in try Self.quotaCases() {
            let classified = GeminiProviderErrors.classify(status: 429, retryAfter: item.retryAfter, body: item.body)
            let table = try #require(expected[item.name])
            #expect(classified.freeTier == item.namesFreeTier, "\(item.name)")
            #expect(classified.transport == table.transport, "\(item.name)")
            #expect(classified.listener == table.listener, "\(item.name)")
        }
    }

    @Test("With the flag only a free-tier answer changes, and only its transport error")
    func classifyWithTheFlag() throws {
        for item in try Self.quotaCases() {
            let off = GeminiProviderErrors.classify(status: 429, retryAfter: item.retryAfter, body: item.body)
            let on = GeminiProviderErrors.classify(status: 429, retryAfter: item.retryAfter, body: item.body, freeTierIsFinal: true)
            if item.namesFreeTier {
                #expect(on.transport == .quotaExhausted, "\(item.name)")
                #expect(on.listener == off.listener, "\(item.name)")
                #expect(on.freeTier, "\(item.name)")
            } else {
                #expect(on == off, "\(item.name)")
            }
        }
    }

    @Test("A send record carries what Google named, and a plain 503 names nothing")
    func sendRecord() async throws {
        let refused = try #require(try Self.quotaCases().first { $0.name.hasPrefix("live-") })
        let log = AnalysisProviderSendLog()
        let model = ProviderTestSupport.googleEntry()
        let free = try ProviderTestSupport.googleTransport(ScriptedHTTPClient(status: 429, body: refused.body), observer: log)
        _ = await ProviderTestSupport.sendResult(free, try ProviderTestSupport.adWindowRequest(model: model))
        let busy = try ProviderTestSupport.googleTransport(ScriptedHTTPClient(status: 503, body: "{}"), observer: log)
        _ = await ProviderTestSupport.sendResult(busy, try ProviderTestSupport.adWindowRequest(model: model))

        #expect(log.sends.map(\.freeTier) == [true, false])
    }

    @Test("An error the trial service passes through is about opencast's key, never the listener's")
    func trialPassThrough() throws {
        let refused = try #require(try Self.quotaCases().first { $0.name.hasPrefix("live-") })
        let direct = GeminiProviderErrors.classify(status: 429, retryAfter: nil, body: refused.body)
        let trial = TrialProxyAnalysisTransport.classify(status: 429, retryAfter: nil, body: refused.body)

        #expect(direct.freeTier)
        #expect(!trial.freeTier)
        #expect(trial.transport == direct.transport)
        #expect(trial.listener == direct.listener)
    }

    // MARK: The tier check

    @Test("Each recorded answer gives its result")
    func recordedAnswers() async throws {
        let fixture = try ProviderTestSupport.providerFixture("gemini-tier-check-cases.json")
        let cases = try #require(fixture["cases"]?.arrayValue)
        #expect(cases.count == 4)
        let results: [String: AnalysisTierCheckResult] = [
            "free_tier": .freeTier,
            "not_free_tier": .notFreeTier,
            "inconclusive": .inconclusive,
        ]
        for item in cases {
            let name = try #require(item["name"]?.stringValue)
            let status = try #require(ProviderJSON.count(item["status"]).flatMap { Int(exactly: $0) })
            let body = try #require(item["body"]?.stringValue)
            let expected = try #require(results[item["expect"]?.stringValue ?? ""])
            let transport = try ProviderTestSupport.googleTransport(ScriptedHTTPClient(status: status, body: body))

            #expect(await transport.checkTier() == expected, "\(name)")
        }
    }

    @Test("A check with no reply is inconclusive", arguments: [AnalysisHTTPFailure.timeout, .network, .oversizedBody])
    func noReply(failure: AnalysisHTTPFailure) async throws {
        let transport = try ProviderTestSupport.googleTransport(ScriptedHTTPClient([.fail(failure)]))

        #expect(await transport.checkTier() == .inconclusive)
    }

    private static func recordedRefusal() throws -> String {
        let refusal = try quotaCases().first { $0.name.hasPrefix("live-") }
        return try #require(refusal?.body)
    }

    @Test("A task cancelled before the check sends nothing and reads as inconclusive, though the client would refuse it as free tier")
    func cancelledBeforeTheCall() async throws {
        let client = ScriptedHTTPClient(status: 429, body: try Self.recordedRefusal())
        let transport = try ProviderTestSupport.googleTransport(client)

        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await transport.checkTier()
        }.value

        #expect(result == .inconclusive)
        #expect(client.requests.isEmpty)
    }

    @Test("A reply that reaches a task cancelled during the check is never read, a refusal or a success")
    func cancelledDuringTheCall() async throws {
        for (status, body) in [(429, try Self.recordedRefusal()), (200, "{}")] {
            let reply = AnalysisHTTPResponse(status: status, retryAfter: nil, body: Data(body.utf8))
            let client = ScriptedHTTPClient([.respond(reply)], cancelsCaller: true)
            let transport = try ProviderTestSupport.googleTransport(client)

            let result = await Task { await transport.checkTier() }.value

            #expect(result == .inconclusive, "\(status)")
            #expect(client.requests.count == 1, "\(status)")
        }
    }

    @Test("The check is one fixed request to the constant model, with the key and the auxiliary deadline")
    func fixedRequest() async throws {
        let client = ScriptedHTTPClient(status: 200, body: "{}")
        let transport = try ProviderTestSupport.googleTransport(client)

        _ = await transport.checkTier()

        let request = try #require(client.requests.first)
        #expect(client.requests.count == 1)
        #expect(request.method == "POST")
        #expect(request.url.path().contains("/models/gemini-pro-latest:generateContent"))
        #expect(String(decoding: try #require(request.body), as: UTF8.self) == #"{"contents":[{"parts":[{"text":"Reply with the single word OK."}],"role":"user"}],"generationConfig":{"maxOutputTokens":16}}"#)
        #expect(request.headers.contains { $0.name == "x-goog-api-key" && $0.value == ProviderTestKeys.google.value })
        #expect(client.timeouts == [AnalysisProviderLimits.auxiliaryCallTimeoutSeconds])
    }

    @Test("The endpoint's model replaces the constant")
    func endpointModel() async throws {
        var endpoint = ProviderTestSupport.googleEndpoint
        endpoint.tierCheckModel = "gemini-paid-only"
        let client = ScriptedHTTPClient(status: 200, body: "{}")
        let transport = try GeminiAnalysisTransport(endpoint: endpoint, key: ProviderTestKeys.google, client: client)

        #expect(await transport.checkTier() == .notFreeTier)
        #expect(try #require(client.requests.first).url.path().contains("/models/gemini-paid-only:generateContent"))
    }

    @Test("An endpoint model that is not a model id sends nothing and says nothing")
    func invalidEndpointModel() async throws {
        var endpoint = ProviderTestSupport.googleEndpoint
        endpoint.tierCheckModel = "../gemini"
        let client = ScriptedHTTPClient(status: 200, body: "{}")
        let transport = try GeminiAnalysisTransport(endpoint: endpoint, key: ProviderTestKeys.google, client: client)

        #expect(await transport.checkTier() == .inconclusive)
        #expect(client.requests.isEmpty)
    }

    @Test("The check is outside any run: it waits for no pacer and records no send")
    func outsideAnyRun() async throws {
        let clock = ManualClock()
        let pacer = AnalysisKeyPacer(maxInFlight: 1, clock: clock)
        await pacer.noteRateLimited(retryAfterSeconds: 600)
        let log = AnalysisProviderSendLog()
        let transport = try ProviderTestSupport.googleTransport(ScriptedHTTPClient(status: 200, body: "{}"), pacer: pacer, observer: log, clock: clock)

        #expect(await transport.checkTier() == .notFreeTier)
        #expect(log.sends.isEmpty)
    }
}
