import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders
import Synchronization
import Testing
@testable import OpenCast

@MainActor
@Suite("Analysis provider key tester")
struct AnalysisProviderKeyTesterTests {
    private let snapshot = AnalysisPolicySnapshot.baked
    private let googleKey = AnalysisKeyFixtures.key(AnalysisKeyFixtures.googleText)
    private let openAIKey = AnalysisKeyFixtures.key(AnalysisKeyFixtures.openAIText)

    @Test("A 2xx from Gemini's countTokens on the ad entry's model is accepted, with only the key header")
    func geminiAccepted() async throws {
        let client = StubAnalysisHTTPClient(.success(response(200, #"{"totalTokens":1}"#)))

        let result = await AnalysisProviderKeyTester(client: client).test(googleKey, provider: .google, snapshot: snapshot)

        #expect(result == .accepted)
        let request = try #require(client.requests.first)
        let modelID = try #require(snapshot.adDetection(provider: .google)?.model.modelID)
        #expect(client.requests.count == 1)
        #expect(request.method == "POST")
        #expect(request.url.host() == AnalysisProvider.google.pinnedHost)
        #expect(request.url.absoluteString == "https://\(AnalysisProvider.google.pinnedHost)/v1beta/models/\(modelID):countTokens")
        #expect(request.header("x-goog-api-key") == AnalysisKeyFixtures.googleText)
        #expect(request.header("authorization") == nil)
        #expect(!String(decoding: request.body ?? Data(), as: UTF8.self).contains(AnalysisKeyFixtures.googleText))
    }

    @Test("Gemini's API_KEY_INVALID is an invalid key")
    func geminiInvalidKey() async {
        let body = #"{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"API_KEY_INVALID","domain":"googleapis.com"}]}}"#
        let client = StubAnalysisHTTPClient(.success(response(400, body)))

        let result = await AnalysisProviderKeyTester(client: client).test(googleKey, provider: .google, snapshot: snapshot)

        #expect(result == .failed(.invalidKey))
    }

    @Test("Gemini's 429 naming billing is billing or quota")
    func geminiBilling() async {
        let body = #"{"error":{"code":429,"message":"Your project has exceeded its billing quota.","status":"RESOURCE_EXHAUSTED"}}"#
        let client = StubAnalysisHTTPClient(.success(response(429, body)))

        let result = await AnalysisProviderKeyTester(client: client).test(googleKey, provider: .google, snapshot: snapshot)

        #expect(result == .failed(.billingOrQuota))
    }

    @Test("A 2xx from OpenAI's GET /models is accepted, with only the bearer header")
    func openAIAccepted() async throws {
        let client = StubAnalysisHTTPClient(.success(response(200, #"{"object":"list","data":[]}"#)))

        let result = await AnalysisProviderKeyTester(client: client).test(openAIKey, provider: .openai, snapshot: snapshot)

        #expect(result == .accepted)
        let request = try #require(client.requests.first)
        #expect(client.requests.count == 1)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://\(AnalysisProvider.openai.pinnedHost)/v1/models")
        #expect(request.header("authorization") == "Bearer \(AnalysisKeyFixtures.openAIText)")
        #expect(request.header("x-goog-api-key") == nil)
        #expect(request.body == nil)
    }

    @Test("OpenAI's 401 is an invalid key")
    func openAIInvalidKey() async {
        let body = #"{"error":{"message":"Incorrect API key provided.","type":"invalid_request_error","code":"invalid_api_key"}}"#
        let client = StubAnalysisHTTPClient(.success(response(401, body)))

        let result = await AnalysisProviderKeyTester(client: client).test(openAIKey, provider: .openai, snapshot: snapshot)

        #expect(result == .failed(.invalidKey))
    }

    @Test("OpenAI's 429 insufficient_quota is billing or quota")
    func openAIInsufficientQuota() async {
        let body = #"{"error":{"message":"You exceeded your current quota.","type":"insufficient_quota","code":"insufficient_quota"}}"#
        let client = StubAnalysisHTTPClient(.success(response(429, body)))

        let result = await AnalysisProviderKeyTester(client: client).test(openAIKey, provider: .openai, snapshot: snapshot)

        #expect(result == .failed(.billingOrQuota))
    }

    @Test("A transport failure is unreachable for either provider")
    func transportFailureIsUnreachable() async {
        let client = StubAnalysisHTTPClient(.failure(.network))
        let tester = AnalysisProviderKeyTester(client: client)

        #expect(await tester.test(googleKey, provider: .google, snapshot: snapshot) == .failed(.unreachable))
        #expect(await tester.test(openAIKey, provider: .openai, snapshot: snapshot) == .failed(.unreachable))
    }

    @Test("No endpoint or no model for the provider is model unavailable, and nothing is sent")
    func missingEndpointOrModel() async {
        var withoutEndpoint = AnalysisPolicyBundle.baked
        withoutEndpoint.providers[.openai] = nil
        var withoutModels = AnalysisPolicyBundle.baked
        withoutModels.features.adDetection.qualifiedModels.removeAll { $0.provider == .openai }
        withoutModels.features.chaptersSummary.allowedModels.removeAll { $0.provider == .openai }
        let client = StubAnalysisHTTPClient(.success(response(200, "{}")))
        let tester = AnalysisProviderKeyTester(client: client)

        #expect(await tester.test(openAIKey, provider: .openai, snapshot: Self.snapshot(withoutEndpoint)) == .failed(.modelUnavailable))
        #expect(await tester.test(openAIKey, provider: .openai, snapshot: Self.snapshot(withoutModels)) == .failed(.modelUnavailable))
        #expect(client.requests.isEmpty)
    }

    @Test("An OpenAI key without an ad-detection entry is tested against the Chapters & Summary entry")
    func openAIFallsBackToChaptersEntry() async {
        var bundle = AnalysisPolicyBundle.baked
        bundle.features.adDetection.qualifiedModels.removeAll { $0.provider == .openai }
        let client = StubAnalysisHTTPClient(.success(response(200, "{}")))

        let result = await AnalysisProviderKeyTester(client: client).test(openAIKey, provider: .openai, snapshot: Self.snapshot(bundle))

        #expect(result == .accepted)
        #expect(client.requests.count == 1)
    }

    @Test("An endpoint the transport refuses is a rejected request, and nothing is sent")
    func refusedEndpointIsRejected() async throws {
        var bundle = AnalysisPolicyBundle.baked
        bundle.providers[.google]?.baseURL = try #require(URL(string: "https://example.com/v1beta"))
        let client = StubAnalysisHTTPClient(.success(response(200, "{}")))

        let result = await AnalysisProviderKeyTester(client: client).test(googleKey, provider: .google, snapshot: Self.snapshot(bundle))

        #expect(result == .failed(.requestRejected))
        #expect(client.requests.isEmpty)
    }

    @Test("A fixed tester answers with its seeded result")
    func fixedTesterAnswersSeededResult() async {
        let tester = FixedAnalysisKeyTester(result: .failed(.rateLimited), delay: .milliseconds(1))

        #expect(await tester.test(googleKey, provider: .google, snapshot: snapshot) == .failed(.rateLimited))
        #expect(await FixedAnalysisKeyTester().test(openAIKey, provider: .openai, snapshot: snapshot) == .accepted)
    }

    @Test("A fixed tester answers its seeded results in call order, the last repeating")
    func fixedTesterAnswersInCallOrder() async {
        let tester = FixedAnalysisKeyTester(results: [.failed(.invalidKey), .accepted])

        #expect(await tester.test(googleKey, provider: .google, snapshot: snapshot) == .failed(.invalidKey))
        #expect(await tester.test(googleKey, provider: .google, snapshot: snapshot) == .accepted)
        #expect(await tester.test(googleKey, provider: .google, snapshot: snapshot) == .accepted)
    }

    @Test("A cancelled fixed test still waits out its delay and answers late")
    func fixedTesterDelaySurvivesCancellation() async {
        let tester = FixedAnalysisKeyTester(result: .failed(.timeout), delay: .milliseconds(300))
        let clock = ContinuousClock()
        let started = clock.now
        let googleKey = googleKey
        let snapshot = snapshot
        let request = Task {
            await tester.test(googleKey, provider: .google, snapshot: snapshot)
        }
        request.cancel()

        #expect(await request.value == .failed(.timeout))
        #expect(clock.now - started >= .milliseconds(250))
    }

    @Test("A gated test answers only once released, cancelled or not, so an older request can finish after a newer one")
    func gatedTestsAnswerWhenReleased() async throws {
        let gate = AnalysisKeyTestReleaseGate(calls: 2)
        let tester = FixedAnalysisKeyTester(results: [.failed(.invalidKey), .accepted], gate: gate)
        let googleKey = googleKey
        let snapshot = snapshot
        let older = Task { await tester.test(googleKey, provider: .google, snapshot: snapshot) }
        try await Task.sleep(for: .milliseconds(50))
        let newer = Task { await tester.test(googleKey, provider: .google, snapshot: snapshot) }
        older.cancel()
        try await Task.sleep(for: .milliseconds(50))

        gate.release(call: 2)
        #expect(await newer.value == .accepted)

        gate.release(call: 1)
        #expect(await older.value == .failed(.invalidKey))
    }

    @Test("The UI test's Darwin notification releases a gated test")
    func gateReleasesOnItsDarwinNotification() async throws {
        let gate = AnalysisKeyTestReleaseGate(calls: 1)
        let answered = Mutex(false)
        let waiting = Task {
            await gate.wait(call: 1)
            answered.withLock { $0 = true }
        }

        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(AnalysisKeyTestReleaseGate.releaseName(call: 1) as CFString),
            nil,
            nil,
            true
        )
        let deadline = ContinuousClock.now + .seconds(5)
        while !answered.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(answered.withLock { $0 })
        gate.release(call: 1)
        await waiting.value
    }

    private func response(_ status: Int, _ body: String) -> AnalysisHTTPResponse {
        AnalysisHTTPResponse(status: status, contentType: "application/json", body: Data(body.utf8))
    }

    private static func snapshot(_ bundle: AnalysisPolicyBundle) -> AnalysisPolicySnapshot {
        AnalysisPolicySnapshot(bundle: bundle, source: .baked, fallbackReason: nil, lastRefreshFailure: nil)
    }
}

/// Answers every exchange with one canned outcome and keeps the requests.
private final class StubAnalysisHTTPClient: AnalysisHTTPClient {
    private let outcome: Result<AnalysisHTTPResponse, AnalysisHTTPFailure>
    private let sent = Mutex<[AnalysisHTTPRequest]>([])

    init(_ outcome: Result<AnalysisHTTPResponse, AnalysisHTTPFailure>) {
        self.outcome = outcome
    }

    var requests: [AnalysisHTTPRequest] {
        sent.withLock { $0 }
    }

    func send(
        _ request: AnalysisHTTPRequest,
        timeoutSeconds: Double,
        maximumBodyBytes: Int
    ) async throws(AnalysisHTTPFailure) -> AnalysisHTTPResponse {
        sent.withLock { $0.append(request) }
        return try outcome.get()
    }
}
