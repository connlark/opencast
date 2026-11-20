/// The service splits its budget across the worst-case waves of windows, retry and repair
/// included. The trial floor only admits a send; it is never taken off the send's timeout.
struct AdRunBudget: Sendable {
    let clock: any AnalysisClock
    let deadline: Double
    let callTimeoutSeconds: Double
    let maxBackoffSeconds: Int
    let sendFloorSeconds: Double
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

func analysisBackoffSeconds(attempt: Int) -> Int {
    min(1 << min(attempt, 4), 20)
}

/// The longest `Retry-After` honoured.
let analysisMaxRetryDelaySeconds = 30
