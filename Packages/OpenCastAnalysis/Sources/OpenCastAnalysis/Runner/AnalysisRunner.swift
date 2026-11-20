/// Returns what the analysis services would for the same answers, and fails closed: an answer
/// that does not validate never yields a partial result.
public struct AnalysisRunner: Sendable {
    public let transport: any AnalysisProviderTransport
    public let clock: any AnalysisClock

    public init(transport: any AnalysisProviderTransport, clock: any AnalysisClock = AnalysisSystemClock()) {
        self.transport = transport
        self.clock = clock
    }

    public func detectAds(_ request: AdAnalysisRequest, policy: AdDetectionAnalysisPolicy) async -> AnalysisOutcome {
        await adEngine(policy, canonicalThinking: policy.model.thinking).run(request)
    }

    public func generateChapters(_ request: TranscriptAnalysisRequest, policy: ChaptersSummaryAnalysisPolicy) async -> AnalysisOutcome {
        await chaptersEngine(policy).run(request)
    }

    /// `nil` leaves the thinking level out of the payload, for answers recorded without one.
    func detectAds(
        _ request: AdAnalysisRequest,
        policy: AdDetectionAnalysisPolicy,
        canonicalThinking: String?
    ) async -> AnalysisOutcome {
        await adEngine(policy, canonicalThinking: canonicalThinking).run(request)
    }

    /// Unlike a run, does not stop at the first failed window.
    func traceAdWindows(
        _ request: AdAnalysisRequest,
        policy: AdDetectionAnalysisPolicy,
        canonicalThinking: String?
    ) async -> [AdWindowTrace] {
        let engine = adEngine(policy, canonicalThinking: canonicalThinking)
        let windows = AdWindowing.windows(of: request, policy: policy.settings)
        let budget = AdRunBudget(
            clock: clock,
            segmentCount: request.segments.count,
            policy: policy.settings,
            model: policy.model,
            execution: policy.executionBudget
        )
        var traces: [AdWindowTrace] = []
        for (index, window) in windows.enumerated() {
            var trace = AdWindowTrace(index: index, payload: .null)
            _ = await engine.analyzeWindow(index, window, single: windows.count == 1, budget: budget, trace: &trace)
            traces.append(trace)
        }
        return traces
    }

    /// Skips request validation, as the service's analysis step does.
    func traceChapters(
        _ request: TranscriptAnalysisRequest,
        policy: ChaptersSummaryAnalysisPolicy
    ) async -> (outcome: AnalysisOutcome, attempts: [ChaptersAttemptTrace]) {
        var attempts: [ChaptersAttemptTrace] = []
        let outcome = await chaptersEngine(policy).runValidated(request, trace: &attempts)
        return (outcome, attempts)
    }

    private func adEngine(_ policy: AdDetectionAnalysisPolicy, canonicalThinking: String?) -> AdRunEngine {
        AdRunEngine(
            policy: policy.settings,
            model: policy.model,
            canonicalThinking: canonicalThinking,
            executionBudget: policy.executionBudget,
            transport: transport,
            clock: clock
        )
    }

    private func chaptersEngine(_ policy: ChaptersSummaryAnalysisPolicy) -> ChaptersRunEngine {
        ChaptersRunEngine(policy: policy.settings, model: policy.model, transport: transport, clock: clock)
    }
}
