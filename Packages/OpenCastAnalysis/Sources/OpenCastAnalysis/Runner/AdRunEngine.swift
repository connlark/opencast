/// Everything one ad-detection window did, for replay comparison and
/// diagnostics. Holds ids, codes and the canonical payloads (which carry
/// transcript text, so traces stay on the device or in private evidence).
public struct AdWindowTrace: Sendable, Hashable {
    public struct Attempt: Sendable, Hashable {
        public var parsed: AdParsedAnswer
        public var validation: AdValidation?
    }

    public var index: Int
    public var payload: JSONValue
    /// `nil` when the first request produced no reply.
    public var initial: Attempt?
    /// The corrective payload, or the code that stopped it being built.
    public var repairPayload: Result<JSONValue, AnalysisCodeError>?
    public var repair: Attempt?
    public var result: Result<AdWindowResult, AnalysisFailure>?
}

/// A window that passed: its answer, usage and notices.
public struct AdWindowResult: Sendable, Hashable {
    public var output: AdModelOutput
    public var usage: AnalysisUsage?
    public var notices: [String]
}

/// One ad-detection run: windows, the per-window ladder of transport
/// attempts and the one repair, then cross-window reconciliation, the
/// global alarms and the response.
struct AdRunEngine: Sendable {
    let policy: AdDetectionPolicy
    let model: AnalysisModelEntry
    /// The thinking level carried in the canonical payload.
    let canonicalThinking: String?
    let transport: any AnalysisProviderTransport
    let clock: any AnalysisClock

    static func failure(
        _ code: AnalysisFailureCode,
        issues: [String] = [],
        window: Int? = nil
    ) -> AnalysisFailure {
        let status = switch code {
        case .adAnalysisIncomplete: 422
        case .network: 502
        default: 503
        }
        return AnalysisFailure(feature: .adDetection, code: code, status: status, issues: issues, windowIndex: window)
    }

    func run(_ request: AdAnalysisRequest) async -> AnalysisOutcome {
        if case .failure(let error) = AnalysisRequestValidation.validate(request) {
            return .failed(AnalysisFailure(
                feature: .adDetection,
                code: AnalysisFailureCode(rawValue: error.code) ?? .invalidTranscriptMetadata,
                status: 400
            ))
        }
        let windows = AdWindowing.windows(of: request, policy: policy)
        let single = windows.count == 1
        let budget = AdRunBudget(clock: clock, segmentCount: request.segments.count, policy: policy, model: model)
        let inFlight = max(1, policy.window.maxInFlight)
        let outcome: Result<[Int: AdWindowResult], AnalysisFailure> = await withTaskGroup(
            of: (Int, Result<AdWindowResult, AnalysisFailure>).self
        ) { group in
            var next = 0
            func launch() {
                let index = next
                let window = windows[index]
                next += 1
                group.addTask {
                    var trace = AdWindowTrace(index: index, payload: .null)
                    return (index, await analyzeWindow(index, window, single: single, budget: budget, trace: &trace))
                }
            }
            while next < min(inFlight, windows.count) { launch() }
            var results: [Int: AdWindowResult] = [:]
            while let (index, result) = await group.next() {
                switch result {
                case .success(let value):
                    results[index] = value
                    if next < windows.count { launch() }
                case .failure(let failure):
                    group.cancelAll()
                    return .failure(failure)
                }
            }
            return .success(results)
        }
        if Task.isCancelled { return .failed(Self.failure(.cancelled)) }
        switch outcome {
        case .failure(let failure):
            return .failed(failure)
        case .success(let results):
            let outcome = finish(request, results: (0..<windows.count).map { results[$0]! })
            if Task.isCancelled { return .failed(Self.failure(.cancelled)) }
            return outcome
        }
    }

    /// Reconciles the windows' answers against the whole transcript.
    func finish(_ request: AdAnalysisRequest, results: [AdWindowResult]) -> AnalysisOutcome {
        var output = AdModelOutput(spans: [])
        var usage: AnalysisUsage?
        var notices: [String] = []
        for result in results {
            output.spans.append(contentsOf: result.output.spans)
            usage = AnalysisUsage.combine(usage, result.usage)
            notices.append(contentsOf: result.notices)
        }
        // Multi-window global alarms have no isolated corrective scope: stop
        // with the evidence intact, never publish a subset.
        let validated = AdValidator.validate(request, output, policy: policy)
        guard validated.isComplete else {
            return .failed(Self.failure(.adAnalysisIncomplete, issues: validated.issues))
        }
        notices.append(contentsOf: validated.notices)
        notices.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        var unique: [String] = []
        for notice in notices where unique.last != notice { unique.append(notice) }
        return .adDetection(AdAnalysisResponse(
            schemaVersion: 1,
            requestID: request.requestID,
            model: model.modelID,
            policy: policy.policy,
            policyRevision: policy.revision,
            spans: validated.spans,
            warnings: unique,
            usage: usage
        ))
    }

    /// One window: the first request, and when its answer does not validate,
    /// exactly one corrective request that must keep every verified break
    /// and every locatable rejected candidate.
    func analyzeWindow(
        _ index: Int,
        _ window: AdAnalysisRequest,
        single: Bool,
        budget: AdRunBudget,
        trace: inout AdWindowTrace
    ) async -> Result<AdWindowResult, AnalysisFailure> {
        let result = await analyzeWindowThrowing(index, window, single: single, budget: budget, trace: &trace)
        trace.result = result
        return result
    }

    private func analyzeWindowThrowing(
        _ index: Int,
        _ window: AdAnalysisRequest,
        single: Bool,
        budget: AdRunBudget,
        trace: inout AdWindowTrace
    ) async -> Result<AdWindowResult, AnalysisFailure> {
        func incomplete(_ issues: [String]) -> Result<AdWindowResult, AnalysisFailure> {
            .failure(Self.failure(.adAnalysisIncomplete, issues: issues, window: index))
        }
        func validate(_ output: AdModelOutput) -> AdValidation {
            single
                ? AdValidator.validate(window, output, policy: policy)
                : AdValidator.validateWindow(window, output, policy: policy)
        }
        let payload = AdCanonicalPayload.payload(
            window,
            policy: policy,
            maxOutputTokens: model.maxOutputTokens,
            thinking: canonicalThinking
        )
        trace.payload = payload
        let first: AdParsedAnswer
        do {
            first = try await call(payload, attempts: AdPipelineConstants.initialAttempts, purpose: .adWindow(index: index), budget: budget)
        } catch {
            return .failure(windowed(error, index))
        }
        let validation = first.output.map(validate)
            ?? AdValidation(issues: [first.issue ?? "v3_missing_output"])
        trace.initial = .init(parsed: first, validation: validation)
        if validation.isComplete, let output = first.output {
            return .success(AdWindowResult(output: output, usage: first.usage, notices: validation.notices))
        }
        do {
            try budget.check()
        } catch {
            return .failure(windowed(error, index))
        }
        guard policy.repair.attempts > 0 else { return incomplete(validation.issues) }
        let corrective = AdRepair.payload(
            payload,
            previous: AdRepair.previousAnswer(first.output),
            issues: validation.issues,
            policy: policy
        )
        trace.repairPayload = corrective
        let correctivePayload: JSONValue
        switch corrective {
        case .failure:
            return .failure(Self.failure(.repairFeedbackExceeded, issues: validation.issues, window: index))
        case .success(let value):
            correctivePayload = value
        }
        let repaired: AdParsedAnswer
        do {
            repaired = try await call(
                correctivePayload,
                attempts: AdPipelineConstants.repairTransportAttempts,
                purpose: .adRepair(index: index),
                budget: budget
            )
        } catch {
            var failure = windowed(error, index)
            if failure.issues.isEmpty { failure.issues = validation.issues }
            return .failure(failure)
        }
        let usage = AnalysisUsage.combine(first.usage, repaired.usage)
        guard let output = repaired.output else {
            trace.repair = .init(parsed: repaired, validation: nil)
            return incomplete([repaired.issue ?? "v3_missing_output"])
        }
        var checked = validate(output)
        let lostCandidate: Bool
        if !AdRepair.preservesVerifiedBreaks(validation, checked) {
            lostCandidate = true
        } else if let old = first.output, checked.isComplete {
            lostCandidate = !AdRepair.preservesCandidateEvidence(window, before: old, after: output, policy: policy)
        } else {
            lostCandidate = false
        }
        if lostCandidate { checked.issues.append("v3_repair_lost_candidate") }
        trace.repair = .init(parsed: repaired, validation: checked)
        guard checked.isComplete else { return incomplete(checked.issues) }
        checked.notices.append("v3_semantic_repair")
        return .success(AdWindowResult(output: output, usage: usage, notices: checked.notices))
    }

    private func windowed(_ error: any Error, _ index: Int) -> AnalysisFailure {
        var failure = (error as? AnalysisFailure) ?? Self.failure(.cancelled)
        failure.windowIndex = index
        return failure
    }

    /// Sends one payload with the transport ladder: retryable statuses and
    /// transport failures back off and resend up to `attempts` sends.
    func call(
        _ payload: JSONValue,
        attempts: Int,
        purpose: AnalysisProviderRequest.Purpose,
        budget: AdRunBudget
    ) async throws(AnalysisFailure) -> AdParsedAnswer {
        let text = JSONWriter.string(payload)
        for attempt in 0..<attempts {
            let timeout = try budget.callTimeout()
            let request = AnalysisProviderRequest(
                feature: .adDetection,
                purpose: purpose,
                model: model,
                payload: payload,
                payloadText: text,
                thinking: model.thinking,
                timeoutSeconds: timeout,
                sendIndex: attempt
            )
            let delay: Int
            switch await sendResult(request) {
            case .success(let reply):
                if Task.isCancelled { throw Self.failure(.cancelled) }
                switch reply {
                case .geminiBody(let body): return AdAnswerParser.parse(geminiBody: body)
                case .answer(let answer): return AdAnswerParser.parse(answer: answer)
                }
            case .failure(let error):
                if Task.isCancelled { throw Self.failure(.cancelled) }
                switch error {
                case .retryable(_, let retryAfter):
                    delay = retryAfter.map { min(max($0, 0), analysisMaxRetryDelaySeconds) }
                        ?? analysisBackoffSeconds(attempt: attempt + 1)
                case .quotaExhausted:
                    throw Self.failure(.quotaExhausted)
                case .rejected:
                    throw Self.failure(.providerRejected)
                case .notArchived:
                    throw Self.failure(.replayMissingReply)
                case .timeout, .network, .oversizedBody, .invalidEncoding:
                    if attempt + 1 == attempts { throw Self.failure(Self.code(for: error)) }
                    delay = analysisBackoffSeconds(attempt: attempt + 1)
                }
            }
            if attempt + 1 == attempts { throw Self.failure(.retryExhausted) }
            try await budget.backoff(seconds: delay)
        }
        throw Self.failure(.retryExhausted)
    }

    private func sendResult(_ request: AnalysisProviderRequest) async -> Result<AnalysisProviderReply, AnalysisTransportError> {
        do {
            return .success(try await transport.send(request))
        } catch {
            return .failure(error)
        }
    }

    static func code(for error: AnalysisTransportError) -> AnalysisFailureCode {
        switch error {
        case .retryable: .retryExhausted
        case .quotaExhausted: .quotaExhausted
        case .rejected: .providerRejected
        case .timeout: .timeout
        case .network: .network
        case .oversizedBody: .responseOversized
        case .invalidEncoding: .responseEncoding
        case .notArchived: .replayMissingReply
        }
    }
}
