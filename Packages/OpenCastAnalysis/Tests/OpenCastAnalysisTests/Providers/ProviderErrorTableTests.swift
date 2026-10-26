import Foundation
@testable import OpenCastAnalysis
@testable import OpenCastAnalysisProviders
import Testing

/// Every row of the provider error table, for both providers: each
/// exchange maps to one pipeline error and one listener-facing case, and a
/// run that meets it never yields a partial result.
@Suite("Provider error table")
struct ProviderErrorTableTests {
    struct Case {
        var name: String
        var provider: AnalysisProvider
        var step: ScriptedHTTPClient.Step
        var transport: AnalysisTransportError
        var listener: AnalysisProviderFailure
    }

    static func cases() throws -> [Case] {
        let fixture = try ProviderTestSupport.providerFixture("error-cases.json")
        return try (fixture["cases"]?.arrayValue ?? []).map { item in
            let name = try #require(item["name"]?.stringValue)
            let provider = try #require(AnalysisProvider(rawValue: item["provider"]?.stringValue ?? ""))
            let step: ScriptedHTTPClient.Step
            switch item["failure"]?.stringValue {
            case "timeout": step = .fail(.timeout)
            case "network": step = .fail(.network)
            case "oversized_body": step = .fail(.oversizedBody)
            default:
                let status = try #require(item["status"].flatMap { ProviderJSON.count($0) }.map { Int($0) })
                let body = try #require(item["body"]?.stringValue)
                step = .respond(AnalysisHTTPResponse(status: status, retryAfter: item["retry_after"]?.stringValue, body: Data(body.utf8)))
            }
            let expect = try #require(item["expect"])
            return Case(
                name: name,
                provider: provider,
                step: step,
                transport: try transportError(try #require(expect["transport"]?.stringValue)),
                listener: try #require(AnalysisProviderFailure(rawValue: expect["listener"]?.stringValue ?? ""))
            )
        }
    }

    static func transportError(_ text: String) throws -> AnalysisTransportError {
        let parts = text.split(separator: ":").map(String.init)
        switch parts[0] {
        case "rejected": return .rejected(status: try #require(Int(parts[1])))
        case "retryable": return .retryable(status: try #require(Int(parts[1])), retryAfterSeconds: parts.count > 2 ? Int(parts[2]) : nil)
        case "quota_exhausted": return .quotaExhausted
        case "timeout": return .timeout
        case "network": return .network
        case "oversized_body": return .oversizedBody
        case "invalid_encoding": return .invalidEncoding
        default: throw StrictDecodingError("unknown transport error \(text)")
        }
    }

    static func transport(_ provider: AnalysisProvider, _ client: ScriptedHTTPClient, observer: AnalysisProviderSendLog, sink: CollectingLogSink? = nil) throws -> any AnalysisKeyedTransport {
        provider == .google
            ? try ProviderTestSupport.googleTransport(client, observer: observer, sink: sink)
            : try ProviderTestSupport.openAITransport(client, observer: observer, sink: sink)
    }

    static func entry(_ provider: AnalysisProvider) -> AnalysisModelEntry {
        provider == .google ? ProviderTestSupport.googleEntry() : ProviderTestSupport.openAIEntry()
    }

    @Test("The table covers both providers and every listener-facing row")
    func coverage() throws {
        let cases = try Self.cases()
        for provider in AnalysisProvider.allCases {
            let rows = Set(cases.filter { $0.provider == provider }.map(\.listener))
            #expect(rows.isSuperset(of: [.invalidKey, .billingOrQuota, .rateLimited, .modelUnavailable, .overloaded, .timeout, .unreachable, .malformedAnswer]), "\(provider)")
            #expect(cases.contains { $0.provider == provider && $0.transport == .retryable(status: 429, retryAfterSeconds: nil) })
            #expect(cases.contains { $0.provider == provider && $0.listener == .rateLimited && $0.transport != .retryable(status: 429, retryAfterSeconds: nil) })
        }
        #expect(cases.contains { $0.provider == .google && $0.listener == .dailyLimit && $0.transport == .quotaExhausted })
    }

    @Test("Each exchange maps to one pipeline error and one listener case")
    func classification() async throws {
        for item in try Self.cases() {
            let log = AnalysisProviderSendLog()
            let transport = try Self.transport(item.provider, ScriptedHTTPClient([item.step]), observer: log)
            let result = await ProviderTestSupport.sendResult(transport, try ProviderTestSupport.adWindowRequest(model: Self.entry(item.provider)))
            #expect(result == .failure(item.transport), "\(item.name)")
            #expect(log.sends.map(\.failure) == [item.listener], "\(item.name)")
        }
    }

    @Test("A run that meets any error fails whole, and the listener case resolves from its sends")
    func runsFailClosed() async throws {
        for item in try Self.cases() {
            let log = AnalysisProviderSendLog()
            let client = ScriptedHTTPClient(Array(repeating: item.step, count: 40))
            let runner = AnalysisRunner(transport: try Self.transport(item.provider, client, observer: log), clock: AnalysisFrozenClock())
            let policy = AdDetectionAnalysisPolicy.service.with(model: Self.entry(item.provider))
            let outcome = await runner.detectAds(try ProviderTestSupport.carouselRequest, policy: policy)
            guard case .failed = outcome else {
                Issue.record("\(item.name) did not fail")
                continue
            }
            #expect(AnalysisProviderFailure.resolve(outcome, sends: log.sends) == item.listener, "\(item.name)")
        }
    }

    @Test("Truncated and schema-echo answers fail closed for both features on both providers")
    func answersFailClosed() async throws {
        let fixture = try ProviderTestSupport.providerFixture("answer-cases.json")
        for item in fixture["cases"]?.arrayValue ?? [] {
            let name = item["name"]?.stringValue ?? "?"
            let provider = try #require(AnalysisProvider(rawValue: item["provider"]?.stringValue ?? ""))
            let body = try #require(item["body"]?.stringValue)
            let step = ScriptedHTTPClient.Step.respond(AnalysisHTTPResponse(status: 200, body: Data(body.utf8)))
            let log = AnalysisProviderSendLog()
            let runner = AnalysisRunner(
                transport: try Self.transport(provider, ScriptedHTTPClient(Array(repeating: step, count: 10)), observer: log),
                clock: AnalysisFrozenClock()
            )
            let outcome: AnalysisOutcome
            if item["feature"]?.stringValue == "chapters" {
                var model = AnalysisModelEntry.serviceChaptersSummary
                model.provider = provider
                model.modelID = Self.entry(provider).modelID
                outcome = await runner.generateChapters(
                    try OpenAIAnalysisTransportTests.chaptersRequest(),
                    policy: ChaptersSummaryAnalysisPolicy.service.with(model: model)
                )
            } else {
                outcome = await runner.detectAds(try ProviderTestSupport.carouselRequest, policy: AdDetectionAnalysisPolicy.service.with(model: Self.entry(provider)))
            }
            guard case .failed(let failure) = outcome else {
                Issue.record("\(name) did not fail")
                continue
            }
            #expect(failure.code.rawValue == item["expect"]?["failure"]?.stringValue, "\(name)")
            #expect(log.sends.allSatisfy { $0.finishReason?.rawValue == item["expect"]?["finish_reason"]?.stringValue }, "\(name)")
            #expect(AnalysisProviderFailure.resolve(outcome, sends: log.sends) == .malformedAnswer, "\(name)")
        }
    }

    @Test("Resolution: success and the pipeline's own refusals have no provider failure")
    func resolution() {
        let ok = AnalysisOutcome.adDetection(AdAnalysisResponse(schemaVersion: 1, requestID: "r", model: "m", policy: "p", policyRevision: nil, spans: [], warnings: [], usage: nil))
        #expect(AnalysisProviderFailure.resolve(ok, sends: []) == nil)
        for code in [AnalysisFailureCode.cancelled, .transcriptTooLong, .emptySegments] {
            #expect(AnalysisProviderFailure.resolve(.failed(AnalysisFailure(feature: .adDetection, code: code, status: 400)), sends: []) == nil)
        }
        let deadline = AnalysisOutcome.failed(AnalysisFailure(feature: .adDetection, code: .analysisDeadlineExhausted, status: 503))
        #expect(AnalysisProviderFailure.resolve(deadline, sends: []) == .timeout)
        // The window that failed the run decides; cancelled siblings never do.
        let rejectedWindow = AnalysisOutcome.failed(AnalysisFailure(feature: .adDetection, code: .providerRejected, status: 502, windowIndex: 1))
        let sends = [
            AnalysisProviderSendRecord(provider: .openai, modelID: "m", feature: .adDetection, purpose: .adWindow(index: 1), sendIndex: 0,
                                       status: 401, finishReason: nil, failure: .invalidKey, usage: nil, pacedSeconds: 0, exchangeSeconds: 0),
            AnalysisProviderSendRecord(provider: .openai, modelID: "m", feature: .adDetection, purpose: .adWindow(index: 0), sendIndex: 0,
                                       status: nil, finishReason: nil, failure: nil, cancelled: true, usage: nil, pacedSeconds: 0, exchangeSeconds: 0),
            AnalysisProviderSendRecord(provider: .openai, modelID: "m", feature: .adDetection, purpose: .adWindow(index: 2), sendIndex: 0,
                                       status: nil, finishReason: nil, failure: .unreachable, usage: nil, pacedSeconds: 0, exchangeSeconds: 0),
        ]
        #expect(AnalysisProviderFailure.resolve(rejectedWindow, sends: sends) == .invalidKey)
        let paced = AnalysisProviderSendRecord(
            provider: .google, modelID: "m", feature: .adDetection, purpose: .adWindow(index: 0), sendIndex: 0,
            status: 429, finishReason: nil, failure: .rateLimited, usage: nil, pacedSeconds: 0, exchangeSeconds: 0
        )
        #expect(AnalysisProviderFailure.resolve(deadline, sends: [paced]) == .rateLimited)
    }
}
