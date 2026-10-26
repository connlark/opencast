import Foundation
@testable import OpenCastAnalysis
@testable import OpenCastAnalysisProviders
import Synchronization
import Testing

/// A trial exchange the tests script: one result per post, in order.
final class ScriptedTrialProxyExchange: AnalysisTrialProxyExchange {
    struct Post: Sendable, Hashable {
        var path: String
        var payloadText: String
        var timeoutSeconds: Double
        var maximumBodyBytes: Int
    }

    private let state: Mutex<(steps: [ScriptedHTTPClient.Step], posts: [Post])>

    init(_ steps: [ScriptedHTTPClient.Step]) {
        state = Mutex((steps, []))
    }

    var posts: [Post] { state.withLock { $0.posts } }

    func post(
        path: String,
        payloadText: String,
        timeoutSeconds: Double,
        maximumBodyBytes: Int
    ) async throws(AnalysisHTTPFailure) -> AnalysisHTTPResponse {
        let step: ScriptedHTTPClient.Step? = state.withLock { state in
            state.posts.append(Post(path: path, payloadText: payloadText, timeoutSeconds: timeoutSeconds, maximumBodyBytes: maximumBodyBytes))
            return state.steps.isEmpty ? nil : state.steps.removeFirst()
        }
        switch step {
        case .respond(let response)?:
            guard response.body.count <= maximumBodyBytes else { throw .oversizedBody }
            return response
        case .fail(let failure)?:
            throw failure
        case nil:
            throw .network
        }
    }
}

@Suite("Trial proxy transport")
struct TrialProxyAnalysisTransportTests {
    let model = ProviderTestSupport.googleEntry()
    static let runID = "6F1A2B3C-4D5E-4F60-8172-93A4B5C6D7E8"

    static func respond(_ status: Int, _ body: String, retryAfter: String? = nil) -> ScriptedHTTPClient.Step {
        .respond(AnalysisHTTPResponse(status: status, retryAfter: retryAfter, body: Data(body.utf8)))
    }

    static func transport(
        _ exchange: ScriptedTrialProxyExchange,
        runID: String = runID,
        observer: (any AnalysisProviderSendObserver)? = nil,
        sink: CollectingLogSink? = nil,
        clock: any AnalysisClock = AnalysisFrozenClock()
    ) -> TrialProxyAnalysisTransport {
        TrialProxyAnalysisTransport(
            runID: runID,
            exchange: exchange,
            observer: observer,
            logger: RedactingLogger(subsystem: nil, sink: sink),
            clock: clock
        )
    }

    @Test("The wrapper carries the feature, run id, window, the Gemini body byte for byte and whole seconds")
    func wrapperShape() async throws {
        let exchange = ScriptedTrialProxyExchange([Self.respond(200, TestSupport.geminiBody("{\"spans\":[]}"))])
        var request = try ProviderTestSupport.adWindowRequest(model: model, timeout: 75.9)
        request.purpose = .adRepair(index: 3)
        let reply = try await Self.transport(exchange).send(request)

        #expect(reply == .geminiBody(TestSupport.geminiBody("{\"spans\":[]}")))
        let post = try #require(exchange.posts.first)
        #expect(post.path == "/v1/trial/analyze")
        #expect(post.maximumBodyBytes == AnalysisProviderLimits.maxResponseBytes)
        #expect(post.timeoutSeconds == 75.9)
        let wrapper = try JSONParser.parse(post.payloadText)
        guard case .object(let members) = wrapper else {
            Issue.record("wrapper is not an object")
            return
        }
        #expect(members.map(\.key) == ["feature", "run_id", "window_index", "request", "timeout_seconds"])
        #expect(wrapper["feature"]?.stringValue == "ad_detection")
        #expect(wrapper["run_id"]?.stringValue == Self.runID)
        #expect(wrapper["window_index"] == .integer(3))
        #expect(wrapper["timeout_seconds"] == .integer(75))
        #expect(post.payloadText.contains(",\"request\":\(request.payloadText),"))
        #expect(!post.payloadText.contains("x-goog-api-key"))
    }

    @Test("timeout_seconds is a whole number from 1 to 600; Chapters sends window 0")
    func timeoutClamp() throws {
        var request = try ProviderTestSupport.adWindowRequest(model: model)
        for (seconds, expected) in [(0.4, 1), (1.99, 1), (600.5, 600), (86_400, 600), (Double.nan, 1)] {
            let text = TrialProxyAnalysisTransport.wrapper(request, runID: Self.runID, timeoutSeconds: seconds)
            #expect(try JSONParser.parse(text)["timeout_seconds"] == .integer(expected), "\(seconds)")
        }
        request.purpose = .chapters(attempt: 2)
        request.feature = .chaptersSummary
        let text = TrialProxyAnalysisTransport.wrapper(request, runID: Self.runID, timeoutSeconds: 300)
        #expect(try JSONParser.parse(text)["window_index"] == .integer(0))
        #expect(try JSONParser.parse(text)["feature"]?.stringValue == "chapters_summary")
    }

    @Test("A run id outside the service's grammar or a window past its bound is refused before anything is sent")
    func refusedBeforeSending() async throws {
        for runID in ["", String(repeating: "a", count: 65), "run id", "run/1", "rün"] {
            let exchange = ScriptedTrialProxyExchange([])
            let log = AnalysisProviderSendLog()
            let result = await ProviderTestSupport.sendResult(
                Self.transport(exchange, runID: runID, observer: log),
                try ProviderTestSupport.adWindowRequest(model: model)
            )
            #expect(result == .failure(.rejected(status: 0)), "\(runID)")
            #expect(exchange.posts.isEmpty)
            #expect(log.sends.map(\.failure) == [.requestRejected])
        }
        var request = try ProviderTestSupport.adWindowRequest(model: model)
        request.purpose = .adWindow(index: 1_024)
        let exchange = ScriptedTrialProxyExchange([])
        let result = await ProviderTestSupport.sendResult(Self.transport(exchange), request)
        #expect(result == .failure(.rejected(status: 0)))
        #expect(exchange.posts.isEmpty)
    }

    @Test("A wrapper above 1,572,864 bytes is refused as a 413 before anything is sent")
    func oversizedWrapper() async throws {
        var request = try ProviderTestSupport.adWindowRequest(model: model)
        let filler = String(repeating: "a", count: TrialProxyAnalysisTransport.maximumWrapperBytes)
        request.payload = .object([JSONMember("contents", .string(filler))])
        request.payloadText = JSONWriter.string(request.payload)
        let exchange = ScriptedTrialProxyExchange([])
        let log = AnalysisProviderSendLog()
        let result = await ProviderTestSupport.sendResult(Self.transport(exchange, observer: log), request)
        #expect(result == .failure(.rejected(status: 413)))
        #expect(exchange.posts.isEmpty)
        #expect(log.sends.map(\.failure) == [.requestRejected])
    }

    struct RefusalCase: Sendable {
        var body: String
        var status: Int
        var transport: AnalysisTransportError
        var listener: AnalysisProviderFailure
    }

    static let refusals: [RefusalCase] = [
        .init(body: #"{"error":"trial_exhausted"}"#, status: 403, transport: .rejected(status: 403), listener: .trialExhausted),
        .init(body: #"{"error":"trial_run_bound"}"#, status: 403, transport: .rejected(status: 403), listener: .trialRunBound),
        .init(body: #"{"error":"trial_paused"}"#, status: 503, transport: .rejected(status: 503), listener: .trialPaused),
        .init(body: #"{"error":"trial_unavailable","retry_after_seconds":10}"#, status: 503,
              transport: .retryable(status: 503, retryAfterSeconds: 10), listener: .trialUnavailable),
        .init(body: #"{"error":"trial_unavailable"}"#, status: 503, transport: .rejected(status: 503), listener: .trialUnavailable),
        .init(body: #"{"error":"trial_disabled"}"#, status: 503, transport: .rejected(status: 503), listener: .trialUnavailable),
        .init(body: #"{"error":"provider_timeout"}"#, status: 504, transport: .timeout, listener: .timeout),
        .init(body: #"{"error":"provider_unreachable"}"#, status: 502, transport: .network, listener: .unreachable),
        .init(body: #"{"error":"provider_body_too_large"}"#, status: 502, transport: .oversizedBody, listener: .malformedAnswer),
        .init(body: #"{"error":"request_invalid"}"#, status: 400, transport: .rejected(status: 400), listener: .requestRejected),
        .init(body: #"{"error":"payload_too_large"}"#, status: 413, transport: .rejected(status: 413), listener: .requestRejected),
        .init(body: #"{"error":"invalid_json"}"#, status: 400, transport: .rejected(status: 400), listener: .requestRejected),
        .init(body: #"{"error":"unknown_key"}"#, status: 401, transport: .rejected(status: 401), listener: .requestRejected),
        .init(body: #"{"error":"invalid_counter"}"#, status: 401, transport: .rejected(status: 401), listener: .requestRejected),
        .init(body: #"{"error":"missing_assertion"}"#, status: 401, transport: .rejected(status: 401), listener: .requestRejected),
        .init(body: #"{"error":"bearer_limited"}"#, status: 429, transport: .rejected(status: 429), listener: .requestRejected),
        .init(body: #"{"error":"something_new"}"#, status: 500, transport: .rejected(status: 500), listener: .requestRejected),
    ]

    @Test("The service's refusals map through the closed table", arguments: refusals)
    func refusalTable(_ item: RefusalCase) {
        let classification = TrialProxyAnalysisTransport.classify(status: item.status, retryAfter: nil, body: item.body)
        #expect(classification.transport == item.transport, "\(item.body)")
        #expect(classification.listener == item.listener, "\(item.body)")
    }

    @Test("Gemini's own errors pass through and are read by the Gemini table")
    func geminiPassThrough() {
        let invalidKey = #"{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"API_KEY_INVALID"}]}}"#
        let modelMissing = #"{"error":{"code":404,"message":"models/gemini-x is not found","status":"NOT_FOUND"}}"#
        let pairs: [(Int, String, String?)] = [(400, invalidKey, nil), (404, modelMissing, nil), (503, "<html>busy</html>", "7"), (429, "{}", "3")]
        for (status, body, retryAfter) in pairs {
            let trial = TrialProxyAnalysisTransport.classify(status: status, retryAfter: retryAfter, body: body)
            let gemini = GeminiProviderErrors.classify(status: status, retryAfter: retryAfter, body: body)
            #expect(trial == gemini, "\(status)")
        }
    }

    @Test("A refusal ends a pipeline send with the trial's listener case, which resolve reports")
    func refusalReachesResolve() async throws {
        for (body, status, listener) in [
            (#"{"error":"trial_exhausted"}"#, 403, AnalysisProviderFailure.trialExhausted),
            (#"{"error":"trial_paused"}"#, 503, .trialPaused),
            (#"{"error":"trial_run_bound"}"#, 403, .trialRunBound),
            (#"{"error":"trial_disabled"}"#, 503, .trialUnavailable),
        ] {
            let exchange = ScriptedTrialProxyExchange(Array(repeating: Self.respond(status, body), count: 4))
            let log = AnalysisProviderSendLog()
            let runner = AnalysisRunner(transport: Self.transport(exchange, observer: log), clock: AnalysisFrozenClock())
            let snapshot = AnalysisPolicySnapshot(bundle: .baked, source: .baked, fallbackReason: nil, lastRefreshFailure: nil)
            var policy = try #require(snapshot.trialAdDetection)
            var settings = policy.settings
            settings.window.maxInFlight = 1
            policy = policy.with(settings: settings)
            let outcome = await runner.detectAds(try ProviderTestSupport.carouselRequest, policy: policy)
            guard case .failed(let failure) = outcome else {
                Issue.record("expected a failure for \(body)")
                continue
            }
            #expect(failure.code == .providerRejected)
            #expect(exchange.posts.count == 1, "a refusal is never retried: \(body)")
            #expect(AnalysisProviderFailure.resolve(outcome, sends: log.sends) == listener)
        }
    }

    @Test("A busy service is waited out with a fresh post each time, counted as paced time")
    func busyIsWaitedOut() async throws {
        let clock = ManualClock()
        let busy = Self.respond(409, #"{"error":"trial_busy","retry_after_seconds":4}"#, retryAfter: "4")
        let exchange = ScriptedTrialProxyExchange([busy, busy, Self.respond(200, TestSupport.geminiBody("{\"spans\":[]}"))])
        let log = AnalysisProviderSendLog()
        let transport = Self.transport(exchange, observer: log, clock: clock)
        let request = try ProviderTestSupport.adWindowRequest(model: model, timeout: 120)
        let task = Task { await ProviderTestSupport.sendResult(transport, request) }
        await clock.waitForSleepers()
        #expect(clock.wakeTimes == [4])
        clock.advance(by: 4)
        await eventually { exchange.posts.count == 2 && clock.sleeperCount == 1 }
        clock.advance(by: 4)
        let result = await task.value

        #expect(result == .success(.geminiBody(TestSupport.geminiBody("{\"spans\":[]}"))))
        let posts = exchange.posts
        #expect(posts.count == 3)
        #expect(posts.map(\.timeoutSeconds) == [120, 116, 112])
        #expect(try posts.map { try JSONParser.parse($0.payloadText)["timeout_seconds"] } == [.integer(120), .integer(116), .integer(112)])
        let send = try #require(log.sends.first)
        #expect(log.sends.count == 1)
        #expect(send.status == 200)
        #expect(send.pacedSeconds == 8)
        #expect(send.exchangeSeconds == 0)
    }

    @Test("Busy waits stop after eight retries and surface as a retryable 409")
    func busyRetriesAreBounded() async throws {
        let busy = Self.respond(409, #"{"error":"trial_busy","retry_after_seconds":0}"#)
        let exchange = ScriptedTrialProxyExchange(Array(repeating: busy, count: 20))
        let log = AnalysisProviderSendLog()
        let clock = SteppingClock()
        let result = await ProviderTestSupport.sendResult(
            Self.transport(exchange, observer: log, clock: clock),
            try ProviderTestSupport.adWindowRequest(model: model, timeout: 120)
        )
        #expect(result == .failure(.retryable(status: 409, retryAfterSeconds: 10)))
        #expect(exchange.posts.count == 1 + TrialProxyAnalysisTransport.maximumBusyRetries)
        #expect(clock.sleeps == Array(repeating: 1, count: TrialProxyAnalysisTransport.maximumBusyRetries))
        #expect(log.sends.map(\.failure) == [.overloaded])
    }

    @Test("A busy wait that would not leave a second before the deadline is not taken")
    func busyRespectsDeadline() async throws {
        let busy = Self.respond(409, #"{"error":"trial_busy","retry_after_seconds":10}"#)
        let exchange = ScriptedTrialProxyExchange([busy, busy])
        let clock = SteppingClock()
        let result = await ProviderTestSupport.sendResult(
            Self.transport(exchange, clock: clock),
            try ProviderTestSupport.adWindowRequest(model: model, timeout: 10.5)
        )
        #expect(result == .failure(.retryable(status: 409, retryAfterSeconds: 10)))
        #expect(exchange.posts.count == 1)
        #expect(clock.sleeps.isEmpty)
    }

    @Test("A busy wait without a hint waits the longest; a busy body on another status is not a busy wait")
    func busyWaitReading() {
        func response(_ status: Int, _ body: String, retryAfter: String? = nil) -> AnalysisHTTPResponse {
            AnalysisHTTPResponse(status: status, retryAfter: retryAfter, body: Data(body.utf8))
        }
        #expect(TrialProxyAnalysisTransport.busyWaitSeconds(response(409, #"{"error":"trial_busy"}"#)) == 10)
        #expect(TrialProxyAnalysisTransport.busyWaitSeconds(response(409, #"{"error":"trial_busy"}"#, retryAfter: "3")) == 3)
        #expect(TrialProxyAnalysisTransport.busyWaitSeconds(response(409, #"{"error":"trial_busy","retry_after_seconds":25}"#)) == 10)
        #expect(TrialProxyAnalysisTransport.busyWaitSeconds(response(503, #"{"error":"trial_busy"}"#)) == nil)
        #expect(TrialProxyAnalysisTransport.busyWaitSeconds(response(409, #"{"error":{"code":409}}"#)) == nil)
    }

    @Test("Exchange failures map like any transport's; nothing about the request reaches a log line")
    func exchangeFailures() async throws {
        for (failure, expected) in [(AnalysisHTTPFailure.timeout, AnalysisTransportError.timeout), (.network, .network), (.oversizedBody, .oversizedBody)] {
            let sink = CollectingLogSink()
            let exchange = ScriptedTrialProxyExchange([.fail(failure)])
            let request = try ProviderTestSupport.adWindowRequest(model: model)
            let result = await ProviderTestSupport.sendResult(Self.transport(exchange, sink: sink), request)
            #expect(result == .failure(expected))
            #expect(sink.all.count == 1)
            #expect(sink.all.allSatisfy { !$0.contains(Self.runID) && !$0.contains("segments") })
        }
        #expect(String(describing: Self.transport(ScriptedTrialProxyExchange([]))) == "TrialProxyAnalysisTransport")
    }
}

/// A clock whose sleeps return at once and move time forward by the slept
/// amount, recording each.
final class SteppingClock: AnalysisClock {
    private let state = Mutex<(now: Double, sleeps: [Double])>((0, []))

    func now() -> Double { state.withLock { $0.now } }

    func sleep(seconds: Double) async throws {
        try Task.checkCancellation()
        state.withLock { state in
            state.now += seconds
            state.sleeps.append(seconds)
        }
    }

    var sleeps: [Double] { state.withLock { $0.sleeps } }
}
