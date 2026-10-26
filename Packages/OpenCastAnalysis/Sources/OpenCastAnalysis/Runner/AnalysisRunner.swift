/// Runs ad detection and Chapters & Summary on the device: builds the
/// canonical requests, sends them through a provider transport, validates
/// every answer exactly as the analysis services do, and returns the
/// response the services would have returned, or the failure they would
/// have reported. Fails closed: an answer that does not validate never
/// yields a partial result.
///
/// Policies come from ``AnalysisPolicySnapshot`` (one feature's settings
/// and the listener's provider entry); the run record keeps their
/// `bundleVersion`, `settings.revision` and `model`.
public struct AnalysisRunner: Sendable {
    public let transport: any AnalysisProviderTransport
    public let clock: any AnalysisClock

    public init(transport: any AnalysisProviderTransport, clock: any AnalysisClock = AnalysisSystemClock()) {
        self.transport = transport
        self.clock = clock
    }

    /// Detects skippable ad breaks across the whole episode.
    public func detectAds(_ request: AdAnalysisRequest, policy: AdDetectionAnalysisPolicy) async -> AnalysisOutcome {
        await adEngine(policy, canonicalThinking: policy.model.thinking).run(request)
    }

    /// Generates chapters and the episode summary.
    public func generateChapters(_ request: TranscriptAnalysisRequest, policy: ChaptersSummaryAnalysisPolicy) async -> AnalysisOutcome {
        await chaptersEngine(policy).run(request)
    }

    /// Detects ads with the canonical payload's thinking level chosen
    /// explicitly; `nil` omits it. For replays of answers recorded without one.
    func detectAds(
        _ request: AdAnalysisRequest,
        policy: AdDetectionAnalysisPolicy,
        canonicalThinking: String?
    ) async -> AnalysisOutcome {
        await adEngine(policy, canonicalThinking: canonicalThinking).run(request)
    }

    /// Analyzes every ad-detection window independently and records what each
    /// did, without the run's early stop on the first failure. For replay
    /// comparison and diagnostics.
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
            model: policy.model
        )
        var traces: [AdWindowTrace] = []
        for (index, window) in windows.enumerated() {
            var trace = AdWindowTrace(index: index, payload: .null)
            _ = await engine.analyzeWindow(index, window, single: windows.count == 1, budget: budget, trace: &trace)
            traces.append(trace)
        }
        return traces
    }

    /// Generates chapters, skipping request validation as the service's
    /// analysis step does, and records each attempt that got a reply.
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
            transport: transport,
            clock: clock
        )
    }

    private func chaptersEngine(_ policy: ChaptersSummaryAnalysisPolicy) -> ChaptersRunEngine {
        ChaptersRunEngine(policy: policy.settings, model: policy.model, transport: transport, clock: clock)
    }
}
