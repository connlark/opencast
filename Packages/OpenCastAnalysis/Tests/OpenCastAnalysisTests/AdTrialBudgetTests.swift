import Foundation
@testable import OpenCastAnalysis
import Testing

/// The trial route's serial execution budget: 1,740 seconds for the run, each
/// send up to the model's per-call timeout while at least 30 seconds remain.
/// The direct route keeps the service's allocation whatever its concurrency.
/// Every run here goes through a transport that holds each send to the
/// timeout it was given.
@Suite("Trial execution budget")
struct AdTrialBudgetTests {
    typealias Step = TestSupport.TimedTransport.Step
    typealias Script = [AnalysisProviderRequest.Purpose: [Step]]

    static let validReply = Result<AnalysisProviderReply, AnalysisTransportError>.success(
        .geminiBody(TestSupport.geminiBody(#"{"spans":[]}"#))
    )

    static func answer(after seconds: Double) -> Step {
        Step(latency: seconds, reply: validReply)
    }

    /// An answer that is not JSON, so the window asks for a repair.
    static func invalid(after seconds: Double, cancels: Bool = false) -> Step {
        Step(latency: seconds, reply: .success(.geminiBody(TestSupport.geminiBody("not json"))), cancels: cancels)
    }

    static func busy(after seconds: Double) -> Step {
        Step(latency: seconds, reply: .failure(.retryable(status: 503, retryAfterSeconds: nil)))
    }

    /// An answer slower than any send's timeout.
    static let overCap = Step(latency: 1_000, reply: validReply)

    /// Windows `0..<count` each time out once at 120 s, pause 2 s and answer
    /// in 120 s: 242 s apiece, so seven leave 46 s of the trial's 1,740.
    static func slowWindows(_ count: Int) -> Script {
        Dictionary(uniqueKeysWithValues: (0..<count).map { (.adWindow(index: $0), [overCap, answer(after: 120)]) })
    }

    /// The trial's policy as `AnalysisRouteResolver.trialPolicy` builds it.
    static func trial(_ settings: AdDetectionPolicy = AdDetectionAnalysisPolicy.service.settings) -> AdDetectionAnalysisPolicy {
        var serial = settings
        serial.window.maxInFlight = 1
        return AdDetectionAnalysisPolicy.service.with(settings: serial, executionBudget: .trial)
    }

    /// A direct policy with one window in flight, as a valid bundle may set.
    static var directSerial: AdDetectionAnalysisPolicy {
        var serial = AdDetectionAnalysisPolicy.service.settings
        serial.window.maxInFlight = 1
        return AdDetectionAnalysisPolicy.service.with(settings: serial)
    }

    /// The fewest segments the baked geometry cuts into `windows` windows.
    static func segments(forWindows windows: Int) -> Int {
        windows == 1 ? 800 : 801 + 680 * (windows - 2)
    }

    /// A completed transcript of three-second segments.
    static func request(segments count: Int) -> AdAnalysisRequest {
        AdAnalysisRequest(
            requestID: "trial-budget-\(count)",
            episodeID: "trial-budget-episode",
            podcastID: "trial-budget-podcast",
            episodeTitle: "A long conversation",
            podcastTitle: "Serial Windows",
            transcript: AdAnalysisTranscript(
                languageCode: "en",
                audioDuration: Double(count * 3),
                fingerprint: "trial-budget-\(count)",
                updatedAt: "2026-11-04T00:00:00Z",
                segmentCount: count
            ),
            segments: (0..<count).map { index in
                AnalysisSegment(id: Int64(index), start: Double(index * 3), end: Double(index * 3 + 3), text: "Segment \(index) of the talk.")
            }
        )
    }

    static func request(windows: Int) -> AdAnalysisRequest {
        request(segments: segments(forWindows: windows))
    }

    func run(
        _ request: AdAnalysisRequest,
        policy: AdDetectionAnalysisPolicy,
        _ scripts: Script = [:],
        every defaultStep: Step? = nil
    ) async -> (AnalysisOutcome, TestSupport.SteppingClock, [AnalysisProviderRequest]) {
        let clock = TestSupport.SteppingClock()
        let transport = TestSupport.TimedTransport(clock: clock, scripts: scripts, defaultStep: defaultStep)
        let outcome = await AnalysisRunner(transport: transport, clock: clock).detectAds(request, policy: policy)
        return (outcome, clock, await transport.sent)
    }

    func failure(_ outcome: AnalysisOutcome) -> AnalysisFailure? {
        if case .failed(let failure) = outcome { return failure }
        return nil
    }

    func succeeded(_ outcome: AnalysisOutcome) -> Bool {
        if case .adDetection = outcome { true } else { false }
    }

    func sends(_ sent: [AnalysisProviderRequest], _ purpose: AnalysisProviderRequest.Purpose) -> [Double] {
        sent.filter { $0.purpose == purpose }.map(\.timeoutSeconds)
    }

    @Test("The synthetic transcripts cut into the intended windows", arguments: [1, 5, 8, 9])
    func syntheticWindows(windows: Int) {
        let request = Self.request(windows: windows)
        #expect(AnalysisRequestValidation.validate(request).failureCode == nil)
        #expect(AdWindowing.windowCount(segmentCount: request.segments.count, policy: AdDetectionAnalysisPolicy.service.settings) == windows)
    }

    @Test("Five serial windows that answer in 40 s each complete with 120-second sends")
    func fiveSerialWindows() async {
        let (outcome, clock, sent) = await run(Self.request(windows: 5), policy: Self.trial(), every: Self.answer(after: 40))
        #expect(succeeded(outcome), "\(outcome)")
        #expect(sent.map(\.purpose) == (0..<5).map { .adWindow(index: $0) })
        #expect(sent.map(\.timeoutSeconds) == Array(repeating: 120, count: 5))
        #expect(clock.now() == 200)
    }

    @Test("Two over-cap attempts are two sends, one 2-second pause, no repair and a timeout")
    func overCapAttempts() async {
        let (outcome, clock, sent) = await run(
            Self.request(windows: 5),
            policy: Self.trial(),
            [.adWindow(index: 0): [Self.overCap, Self.overCap]],
            every: Self.answer(after: 40)
        )
        #expect(failure(outcome)?.code == .timeout)
        #expect(failure(outcome)?.windowIndex == 0)
        #expect(sent.map(\.purpose) == [.adWindow(index: 0), .adWindow(index: 0)])
        #expect(sent.map(\.timeoutSeconds) == [120, 120])
        #expect(clock.recordedPauses == [2])
    }

    @Test("A serial run may outlast the service's 570 seconds: twelve windows of 60 s")
    func twelveWindowsPastTheServiceBudget() async {
        // A narrower valid geometry gives twelve windows, the trial's run bound.
        var settings = AdDetectionAnalysisPolicy.service.settings
        settings.window.segments = 400
        settings.window.overlap = 60
        let request = Self.request(segments: 4_000)
        #expect(AdWindowing.windowCount(segmentCount: 4_000, policy: settings) == 12)
        let (outcome, clock, sent) = await run(request, policy: Self.trial(settings), every: Self.answer(after: 60))
        #expect(succeeded(outcome), "\(outcome)")
        #expect(sent.map(\.timeoutSeconds) == Array(repeating: 120, count: 12))
        #expect(clock.now() == 720)
        #expect(clock.now() > Double(AdDetectionAnalysisPolicy.service.model.runBudgetSeconds))
    }

    @Test("A send gets what is left under the cap, and its answer completes the run below the floor")
    func clippingAndFinalSuccessBelowTheFloor() async {
        var script = Self.slowWindows(7)
        script[.adWindow(index: 7)] = [Self.answer(after: 40)]
        let (outcome, clock, sent) = await run(Self.request(windows: 8), policy: Self.trial(), script)
        #expect(succeeded(outcome), "\(outcome)")
        #expect(sends(sent, .adWindow(index: 6)) == [120, 120])
        #expect(sends(sent, .adWindow(index: 7)) == [46])
        #expect(clock.now() == 1_734)
    }

    @Test("A send starts with exactly 30 s left and not with less; nothing is sent after", arguments: [
        (16.0, true), (16.5, false),
    ])
    func sendFloor(latency: Double, admitted: Bool) async {
        var script = Self.slowWindows(7)
        script[.adWindow(index: 7)] = [Self.answer(after: latency)]
        script[.adWindow(index: 8)] = [Self.answer(after: 20)]
        let (outcome, clock, sent) = await run(Self.request(windows: 9), policy: Self.trial(), script)
        if admitted {
            #expect(succeeded(outcome), "\(outcome)")
            #expect(sends(sent, .adWindow(index: 8)) == [30])
            #expect(clock.now() == 1_730)
        } else {
            #expect(failure(outcome)?.code == .analysisDeadlineExhausted)
            #expect(failure(outcome)?.windowIndex == 8)
            #expect(sends(sent, .adWindow(index: 8)).isEmpty)
            #expect(sent.count == 15)
            #expect(clock.now() == 1_710.5)
        }
    }

    @Test("A repair is admitted with exactly 30 s left and refused below", arguments: [
        (16.0, true), (16.5, false),
    ])
    func repairAdmission(latency: Double, admitted: Bool) async {
        var script = Self.slowWindows(7)
        script[.adWindow(index: 7)] = [Self.invalid(after: latency)]
        script[.adRepair(index: 7)] = [Self.answer(after: 25)]
        let (outcome, clock, sent) = await run(Self.request(windows: 8), policy: Self.trial(), script)
        if admitted {
            guard case .adDetection(let response) = outcome else {
                Issue.record("expected a response, got \(outcome)")
                return
            }
            #expect(response.warnings.contains("v3_semantic_repair"))
            #expect(sends(sent, .adRepair(index: 7)) == [30])
            // The repair's answer finishes the run with 5 s left.
            #expect(clock.now() == 1_735)
        } else {
            #expect(failure(outcome)?.code == .analysisDeadlineExhausted)
            #expect(failure(outcome)?.windowIndex == 7)
            #expect(sends(sent, .adRepair(index: 7)).isEmpty)
            #expect(clock.now() == 1_710.5)
        }
    }

    @Test("A pause must leave 30 s for the send after it", arguments: [
        (14.0, true), (14.5, false),
    ])
    func backoffFloor(latency: Double, admitted: Bool) async {
        var script = Self.slowWindows(7)
        script[.adWindow(index: 7)] = [Self.busy(after: latency), Self.answer(after: 10)]
        let (outcome, clock, sent) = await run(Self.request(windows: 8), policy: Self.trial(), script)
        if admitted {
            #expect(succeeded(outcome), "\(outcome)")
            #expect(clock.recordedPauses == Array(repeating: 2, count: 8))
            #expect(sends(sent, .adWindow(index: 7)) == [46, 30])
        } else {
            #expect(failure(outcome)?.code == .analysisDeadlineExhausted)
            #expect(failure(outcome)?.windowIndex == 7)
            #expect(clock.recordedPauses == Array(repeating: 2, count: 7))
            #expect(sends(sent, .adWindow(index: 7)) == [46])
        }
    }

    @Test("Cancellation outranks the floor and stops further sends", arguments: [7, 1])
    func cancellation(window: Int) async {
        var script = Self.slowWindows(window)
        // At window 7 the 16.5 s answer leaves 29.5 s, below the floor its
        // repair would need; at window 1 there is time to spare.
        script[.adWindow(index: window)] = [Self.invalid(after: 16.5, cancels: true)]
        let (outcome, _, sent) = await run(Self.request(windows: 8), policy: Self.trial(), script, every: Self.answer(after: 40))
        #expect(failure(outcome)?.code == .cancelled)
        #expect(sent.last?.purpose == .adWindow(index: window))
        #expect(sent.count == 2 * window + 1)
    }

    @Test("A direct policy with one window in flight keeps the service's allocation")
    func directSerialUnchanged() async {
        let policy = Self.directSerial
        #expect(policy.executionBudget == .service)
        let (outcome, clock, sent) = await run(Self.request(windows: 5), policy: policy, every: Self.answer(after: 40))
        #expect(failure(outcome)?.code == .timeout)
        #expect(sent.map(\.timeoutSeconds) == [34, 34])
        #expect(clock.recordedPauses == [2])
    }

    @Test("The service allocation keeps its tables at four and at one window in flight", arguments: [
        (4, 1, 120), (4, 4, 120), (4, 5, 91), (4, 8, 91), (4, 9, 60), (4, 12, 60), (4, 13, 44), (4, 16, 44), (4, 17, 34), (4, 20, 34),
        (1, 1, 120), (1, 2, 91), (1, 3, 60), (1, 4, 44), (1, 5, 34), (1, 6, 28), (1, 8, 20), (1, 10, 15), (1, 12, 12),
    ])
    func serviceTables(inFlight: Int, windows: Int, seconds: Double) {
        var settings = AdDetectionAnalysisPolicy.service.settings
        settings.window.maxInFlight = inFlight
        let budget = AdRunBudget(
            clock: TestSupport.SteppingClock(),
            segmentCount: Self.segments(forWindows: windows),
            policy: settings,
            model: .serviceAdDetection,
            execution: .service
        )
        #expect(budget.callTimeoutSeconds == seconds)
        #expect(budget.deadline == 570)
        #expect(budget.sendFloorSeconds == 1)
        #expect(budget.backoffReserveSeconds == seconds)
    }

    @Test("The trial allocation is the model's cap for every window count", arguments: [1, 5, 9, 12, 20])
    func trialAllocation(windows: Int) {
        let budget = AdRunBudget(
            clock: TestSupport.SteppingClock(),
            segmentCount: Self.segments(forWindows: windows),
            policy: Self.trial().settings,
            model: .serviceAdDetection,
            execution: .trial
        )
        #expect(budget.callTimeoutSeconds == 120)
        #expect(budget.deadline == 1_740)
        #expect(budget.sendFloorSeconds == 30)
        #expect(budget.backoffReserveSeconds == 30)
    }

    @Test("Only an explicit choice selects the trial budget")
    func selection() {
        let service = AdDetectionAnalysisPolicy.service
        let snapshot = AnalysisPolicySnapshot(bundle: .baked, source: .baked, fallbackReason: nil, lastRefreshFailure: nil)
        #expect(service.executionBudget == .service)
        #expect(snapshot.adDetection(provider: .google)?.executionBudget == .service)
        #expect(snapshot.trialAdDetection?.executionBudget == .service)
        #expect(snapshot.chaptersSummary(provider: .google)?.executionBudget == .service)
        #expect(Self.directSerial.executionBudget == .service)
        let trial = service.with(executionBudget: .trial)
        #expect(trial.with(settings: Self.directSerial.settings).with(model: .serviceAdDetection).executionBudget == .trial)
        #expect(trial != service)
        #expect(ChaptersSummaryAnalysisPolicy.service.with(model: .serviceChaptersSummary).executionBudget == .service)
    }
}
