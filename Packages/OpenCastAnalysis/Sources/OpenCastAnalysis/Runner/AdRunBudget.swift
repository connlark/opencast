/// The finite wall budget of one ad-detection run. The service's budget is
/// allocated across the worst-case waves of windows including the transport
/// retry and the semantic repair, so a short episode can wait for a slow
/// valid answer without extending the whole run. The trial's serial budget
/// gives each send up to the model's per-call timeout while the floor is
/// left; the floor admits sends and never cuts one short.
struct AdRunBudget: Sendable {
    let clock: any AnalysisClock
    let deadline: Double
    let callTimeoutSeconds: Double
    let maxBackoffSeconds: Int
    /// The least time left that admits a send.
    let sendFloorSeconds: Double
    /// The time a pause must leave before the deadline.
    let backoffReserveSeconds: Double

    init(
        clock: any AnalysisClock,
        segmentCount: Int,
        policy: AdDetectionPolicy,
        model: AnalysisModelEntry,
        execution: AnalysisExecutionBudget
    ) {
        self.clock = clock
        maxBackoffSeconds = AdPipelineConstants.maxBackoffSeconds
        switch execution {
        case .service:
            deadline = clock.now() + Double(model.runBudgetSeconds)
            callTimeoutSeconds = Double(Self.callTimeoutSeconds(segmentCount: segmentCount, policy: policy, model: model))
            sendFloorSeconds = 1
            backoffReserveSeconds = callTimeoutSeconds
        case .trial:
            deadline = clock.now() + Double(AdTrialRunConstants.runBudgetSeconds)
            callTimeoutSeconds = Double(model.perCallTimeoutSeconds)
            sendFloorSeconds = Double(AdTrialRunConstants.sendFloorSeconds)
            backoffReserveSeconds = sendFloorSeconds
        }
    }

    /// `((budget / waves) - backoff) / attempts`, capped by the model's
    /// per-call timeout, in whole seconds.
    static func callTimeoutSeconds(segmentCount: Int, policy: AdDetectionPolicy, model: AnalysisModelEntry) -> Int {
        let windows = AdWindowing.windowCount(segmentCount: segmentCount, policy: policy)
        let inFlight = max(1, policy.window.maxInFlight)
        let waves = (windows + inFlight - 1) / inFlight
        let backoff = AdPipelineConstants.maxBackoffSeconds * max(0, AdPipelineConstants.initialAttempts - 1)
        let perWave = max(0, model.runBudgetSeconds / waves - backoff)
        let repairSends = policy.repair.attempts > 0 ? AdPipelineConstants.repairTransportAttempts : 0
        let attempts = max(1, AdPipelineConstants.initialAttempts + repairSends)
        return min(perWave / attempts, model.perCallTimeoutSeconds)
    }

    func check() throws(AnalysisFailure) {
        if Task.isCancelled { throw AdRunEngine.failure(.cancelled) }
        if clock.now() >= deadline { throw AdRunEngine.failure(.analysisDeadlineExhausted) }
    }

    func callTimeout() throws(AnalysisFailure) -> Double {
        try check()
        let remaining = deadline - clock.now()
        if remaining < sendFloorSeconds { throw AdRunEngine.failure(.analysisDeadlineExhausted) }
        return min(remaining, callTimeoutSeconds)
    }

    func backoff(seconds: Int) async throws(AnalysisFailure) {
        try check()
        if seconds > maxBackoffSeconds || clock.now() + Double(seconds) + backoffReserveSeconds > deadline {
            throw AdRunEngine.failure(.analysisDeadlineExhausted)
        }
        do {
            try await clock.sleep(seconds: Double(seconds))
        } catch {
            throw AdRunEngine.failure(.cancelled)
        }
        try check()
    }
}

/// Exponential backoff between attempts without a `Retry-After`: 2, 4, 8,
/// then 16 seconds (`min(2^min(attempt, 4), 20)`).
func analysisBackoffSeconds(attempt: Int) -> Int {
    min(1 << min(attempt, 4), 20)
}

/// The longest `Retry-After` honoured.
let analysisMaxRetryDelaySeconds = 30
