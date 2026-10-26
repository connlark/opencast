import Foundation
@testable import OpenCastAnalysis
import Testing

@Suite("Analysis runner")
struct AnalysisRunnerTests {
    static let carousel: AdAnalysisRequest = {
        let goldens = try! TestSupport.fixture("parity-goldens.json")
        return try! AdAnalysisRequest(json: goldens["fixtures"]!["synthetic-carousel"]!)
    }()

    static let chapters: TranscriptAnalysisRequest = {
        let goldens = try! TestSupport.fixture("parity-goldens.json")
        return try! TranscriptAnalysisRequest(json: goldens["fixtures"]!["synthetic-chapters-40"]!)
    }()

    static let validAds = #"{"spans":[{"kind":"house_or_network_promo","label":"Sister show promo","start_segment_id":120,"end_segment_id":120,"confidence":0.85,"evidence_quote":"Five Minute Gardens","start_quote":"Try our sister show, Five Minute Gardens","end_quote":"Subscribe wherever you listen to podcasts"}]}"#

    static let validChapters = #"{"chapters":[{"title":"Planning","start_segment_id":0,"end_segment_id":19,"confidence":0.9},{"title":"Repair","start_segment_id":20,"end_segment_id":39,"confidence":0.9}],"summary":{"summary":"Two hosts restore a boat.","one_line_description":"A winter of repair","claims":[{"text":"They sanded the transom.","evidence_segment_id":1}]}}"#

    func runAds(
        _ script: [AnalysisProviderRequest.Purpose: [Result<AnalysisProviderReply, AnalysisTransportError>]],
        clock: TestSupport.SteppingClock = .init()
    ) async -> (AnalysisOutcome, TestSupport.SteppingClock, TestSupport.ScriptedTransport) {
        let transport = TestSupport.ScriptedTransport(script)
        let runner = AnalysisRunner(transport: transport, clock: clock)
        return (await runner.detectAds(Self.carousel, policy: .service), clock, transport)
    }

    func failureCode(_ outcome: AnalysisOutcome) -> AnalysisFailureCode? {
        if case .failed(let failure) = outcome { return failure.code }
        return nil
    }

    @Test("A retryable status backs off and resends")
    func retryThenSuccess() async {
        let (outcome, clock, transport) = await runAds([
            .adWindow(index: 0): [.failure(.retryable(status: 503, retryAfterSeconds: nil)), .success(.geminiBody(TestSupport.geminiBody(Self.validAds)))],
        ])
        guard case .adDetection(let response) = outcome else {
            Issue.record("expected a response, got \(outcome)")
            return
        }
        #expect(response.spans.count == 1)
        #expect(clock.recordedPauses == [2])
        #expect(await transport.sent.map(\.sendIndex) == [0, 1])
        #expect(await transport.sent.first?.timeoutSeconds == 120)
    }

    @Test("Transport failures end the window with the services' codes", arguments: [
        ([AnalysisTransportError.quotaExhausted], AnalysisFailureCode.quotaExhausted),
        ([.rejected(status: 400)], .providerRejected),
        ([.timeout, .timeout], .timeout),
        ([.network, .network], .network),
        ([.retryable(status: 500, retryAfterSeconds: nil), .retryable(status: 500, retryAfterSeconds: nil)], .retryExhausted),
        ([.retryable(status: 429, retryAfterSeconds: 30)], .analysisDeadlineExhausted),
        ([.oversizedBody, .oversizedBody], .responseOversized),
    ])
    func transportFailures(errors: [AnalysisTransportError], code: AnalysisFailureCode) async {
        let (outcome, _, _) = await runAds([.adWindow(index: 0): errors.map { .failure($0) }])
        #expect(failureCode(outcome) == code)
    }

    @Test("A cancelled run reports cancellation")
    func cancellation() async {
        let transport = TestSupport.ScriptedTransport([:])
        let runner = AnalysisRunner(transport: transport, clock: TestSupport.SteppingClock())
        let task = Task { await runner.detectAds(Self.carousel, policy: .service) }
        task.cancel()
        let outcome = await task.value
        #expect(failureCode(outcome) == .cancelled)
    }

    /// Cancels the task that sends, then delivers a valid answer.
    struct CancellingTransport: AnalysisProviderTransport {
        let body: String

        func send(_ request: AnalysisProviderRequest) async throws(AnalysisTransportError) -> AnalysisProviderReply {
            withUnsafeCurrentTask { $0?.cancel() }
            return .geminiBody(body)
        }
    }

    @Test("A run cancelled while a reply is in flight reports cancellation, not the reply")
    func cancellationDuringReply() async {
        let ads = AnalysisRunner(transport: CancellingTransport(body: TestSupport.geminiBody(Self.validAds)), clock: TestSupport.SteppingClock())
        #expect(failureCode(await ads.detectAds(Self.carousel, policy: .service)) == .cancelled)
        let chapters = AnalysisRunner(
            transport: CancellingTransport(body: TestSupport.geminiBody(Self.validChapters)),
            clock: TestSupport.SteppingClock()
        )
        #expect(failureCode(await chapters.generateChapters(Self.chapters, policy: .service)) == .cancelled)
    }

    @Test("A tightened evidence policy cannot let a repair drop a locatable candidate")
    func tightEvidencePolicyKeepsPreservation() async throws {
        let service = AdDetectionAnalysisPolicy.service
        var settings = service.settings
        settings.limits.evidenceWords = 2
        // The four-word cue fails the tightened evidence check, so the window
        // asks for a repair; the repair shrinks the break away from the cue.
        let initial = #"{"spans":[{"kind":"house_or_network_promo","label":"Trailers","start_segment_id":20,"end_segment_id":50,"confidence":0.95,"evidence_quote":"Listen to Harbor Letters","start_quote":"I'm Mira, and this is Harbor Letters","end_quote":"Subscribe to Backstage Supper wherever you get podcasts"}]}"#
        let repaired = #"{"spans":[{"kind":"house_or_network_promo","label":"Trailer","start_segment_id":20,"end_segment_id":20,"confidence":0.95,"evidence_quote":"documentary podcast","start_quote":"I'm Mira, and this is Harbor Letters","end_quote":"the boat disappeared"}]}"#
        let transport = TestSupport.ScriptedTransport([
            .adWindow(index: 0): [.success(.geminiBody(TestSupport.geminiBody(initial)))],
            .adRepair(index: 0): [.success(.geminiBody(TestSupport.geminiBody(repaired)))],
        ])
        let runner = AnalysisRunner(transport: transport, clock: TestSupport.SteppingClock())
        let outcome = await runner.detectAds(Self.carousel, policy: service.with(settings: settings))
        guard case .failed(let failure) = outcome else {
            Issue.record("expected the repair to be refused, got \(outcome)")
            return
        }
        #expect(failure.code == .adAnalysisIncomplete)
        #expect(failure.issues.contains("v3_repair_lost_candidate"))
    }

    @Test("Per-call timeouts share the run budget across waves of windows", arguments: [
        (12, 120), (1_399, 120), (4_000, 91), (6_000, 60),
    ])
    func callTimeouts(segments: Int, seconds: Int) {
        #expect(AdRunBudget.callTimeoutSeconds(
            segmentCount: segments,
            policy: AdDetectionAnalysisPolicy.service.settings,
            model: .serviceAdDetection
        ) == seconds)
    }

    @Test("Window counts follow 1 + ceil((n - 800) / 680)", arguments: [
        (1, 1), (800, 1), (801, 2), (1_480, 2), (1_481, 3), (6_000, 9),
    ])
    func windowCounts(segments: Int, windows: Int) {
        #expect(AdWindowing.windowCount(segmentCount: segments, policy: AdDetectionAnalysisPolicy.service.settings) == windows)
    }

    @Test("Request validation rejects what the services reject")
    func requestValidation() {
        var request = Self.carousel
        request.segments[1].id = request.segments[0].id
        #expect(AnalysisRequestValidation.validate(request).failureCode == "duplicate_segment_id")
        request = Self.carousel
        request.segments[2].start = 1
        #expect(AnalysisRequestValidation.validate(request).failureCode == "non_monotonic_segments")
        request = Self.carousel
        request.transcript.segmentCount = 3
        #expect(AnalysisRequestValidation.validate(request).failureCode == "segment_count_mismatch")
        request = Self.carousel
        request.transcript.state = "running"
        #expect(AnalysisRequestValidation.validate(request).failureCode == "transcript_not_completed")
        request = Self.carousel
        request.segments[0].text = String(repeating: "x", count: 2_001)
        #expect(AnalysisRequestValidation.validate(request).failureCode == "segment_text_too_large")
        #expect(AnalysisRequestValidation.validate(Self.carousel).failureCode == nil)
    }

    @Test("Chapters retries escalate after a timed-out ladder")
    func chaptersTimeoutLadder() async {
        let transport = TestSupport.ScriptedTransport([
            .chapters(attempt: 0): [.failure(.timeout), .failure(.timeout)],
            .chapters(attempt: 1): [.success(.geminiBody(TestSupport.geminiBody(Self.validChapters)))],
        ])
        let runner = AnalysisRunner(transport: transport, clock: TestSupport.SteppingClock())
        let outcome = await runner.generateChapters(Self.chapters, policy: .service)
        guard case .chaptersSummary(let response) = outcome else {
            Issue.record("expected chapters, got \(outcome)")
            return
        }
        #expect(response.warnings == ["gemini_timeout_retried_high"])
        let sent = await transport.sent
        #expect(sent.map(\.thinking) == ["medium", "medium", "high"])
        #expect(sent.map(\.timeoutSeconds) == [120, 120, 300])
    }

    @Test("Chapters fast failures use five sends with capped backoff")
    func chaptersFastFailures() async {
        let clock = TestSupport.SteppingClock()
        let transport = TestSupport.ScriptedTransport([
            .chapters(attempt: 0): Array(repeating: .failure(.retryable(status: 503, retryAfterSeconds: nil)), count: 5),
            .chapters(attempt: 1): [.failure(.quotaExhausted)],
        ])
        let runner = AnalysisRunner(transport: transport, clock: clock)
        let outcome = await runner.generateChapters(Self.chapters, policy: .service)
        #expect(failureCode(outcome) == .quotaExhausted)
        #expect(clock.recordedPauses == [2, 4, 8, 16, 16])
    }

    /// A transport whose one slow call uses most of the run budget.
    struct SlowTransport: AnalysisProviderTransport {
        let clock: TestSupport.SteppingClock

        func send(_ request: AnalysisProviderRequest) async throws(AnalysisTransportError) -> AnalysisProviderReply {
            clock.advance(520)
            return .geminiBody(TestSupport.geminiBody("not json"))
        }
    }

    @Test("Chapters stops when the budget cannot fit another call")
    func chaptersBudget() async {
        let clock = TestSupport.SteppingClock()
        let runner = AnalysisRunner(transport: SlowTransport(clock: clock), clock: clock)
        let outcome = await runner.generateChapters(Self.chapters, policy: .service)
        // 20 s left is under the 30 s floor, so the escalated attempt never
        // starts and the run ends with the first attempt's failure.
        guard case .failed(let failure) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(failure.code == .invalidModelOutput)
        #expect(failure.status == 502)
    }

    @Test("Gemini error statuses map like the services classify them")
    func geminiClassification() {
        let quota = #"{"error":{"code":429,"message":"You exceeded your current quota, check your billing","status":"RESOURCE_EXHAUSTED"}}"#
        let transient = #"{"error":{"code":429,"message":"Resource has been exhausted, try again","status":"RESOURCE_EXHAUSTED"}}"#
        #expect(GeminiErrorClassifier.error(status: 429, retryAfter: nil, body: quota) == .quotaExhausted)
        #expect(GeminiErrorClassifier.error(status: 429, retryAfter: " 12 ", body: transient) == .retryable(status: 429, retryAfterSeconds: 12))
        #expect(GeminiErrorClassifier.error(status: 503, retryAfter: "999", body: "") == .retryable(status: 503, retryAfterSeconds: 30))
        #expect(GeminiErrorClassifier.error(status: 400, retryAfter: nil, body: quota) == .rejected(status: 400))
        #expect(GeminiErrorClassifier.error(status: 429, retryAfter: nil, body: #"{"error":{"code":"x","message":"quota","status":"RESOURCE_EXHAUSTED"}}"#)
            == .retryable(status: 429, retryAfterSeconds: nil))
        #expect(GeminiErrorClassifier.error(status: 429, retryAfter: nil, body: #"{"error":{"message":"quota exceeded","status":"RESOURCE_EXHAUSTED"}}"#)
            == .quotaExhausted)
        #expect(GeminiErrorClassifier.error(status: 429, retryAfter: nil, body: #"{"error":{"code":null,"message":"quota exceeded","status":"RESOURCE_EXHAUSTED"}}"#)
            == .quotaExhausted)
        #expect(GeminiErrorClassifier.error(status: 429, retryAfter: nil, body: #"{"error":{"code":70000,"message":"quota","status":"RESOURCE_EXHAUSTED"}}"#)
            == .retryable(status: 429, retryAfterSeconds: nil))
        // Rust searches bytes: a combining accent after "quota" still matches.
        #expect(GeminiErrorClassifier.error(status: 429, retryAfter: nil, body: #"{"error":{"message":"quota\u0301 exceeded","status":"RESOURCE_EXHAUSTED"}}"#)
            == .quotaExhausted)
        #expect(GeminiErrorClassifier.retryAfterSeconds("soon") == nil)
        #expect(GeminiErrorClassifier.retryAfterSeconds("-1") == nil)
        #expect(GeminiErrorClassifier.retryAfterSeconds("+7") == 7)
        #expect(GeminiErrorClassifier.retryAfterSeconds("99999999999999999999999") == nil)
    }

    @Test("Normalized answers raise the total to the sum of its parts")
    func normalizedUsage() {
        let answer = AnalysisProviderAnswer(
            texts: [Self.validAds],
            finishReason: "STOP",
            usage: AnalysisUsage(promptTokenCount: 10, candidatesTokenCount: 5, thoughtsTokenCount: 7, totalTokenCount: 15)
        )
        #expect(AdAnswerParser.parse(answer: answer).usage?.totalTokenCount == 22)
        #expect(ChaptersAnswerParser.parse(answer: answer).usage?.totalTokenCount == 22)
    }
}

extension Result where Failure == AnalysisCodeError {
    var failureCode: String? {
        if case .failure(let error) = self { return error.code }
        return nil
    }
}
