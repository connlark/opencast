/// Everything one Chapters & Summary attempt did, for replay comparison.
public struct ChaptersAttemptTrace: Sendable, Hashable {
    public var attempt: Int
    public var thinking: String
    public var payload: JSONValue
    public var parsed: ChaptersParsedAnswer?
    public var result: Result<ChaptersValidatedAnalysis, ChaptersRejection>?
}

/// The whole-run budget of a Chapters & Summary run. Every call's deadline
/// is the smaller of its level's cap and what is left; a call never starts
/// with less than the floor left, and a pause is refused when it would not
/// leave room for the call after it.
struct ChaptersRunBudget: Sendable {
    let clock: any AnalysisClock
    let deadline: Double
    let runBudgetSeconds: Int
    let floorSeconds: Int
    let baseCapSeconds: Int
    let escalatedCapSeconds: Int
    let escalatedThinking: String

    init(clock: any AnalysisClock, policy: ChaptersSummaryPolicy, model: AnalysisModelEntry) {
        self.clock = clock
        runBudgetSeconds = model.runBudgetSeconds
        deadline = clock.now() + Double(model.runBudgetSeconds)
        floorSeconds = ChaptersPipelineConstants.budgetFloorSeconds
        baseCapSeconds = model.perCallTimeoutSeconds
        escalatedCapSeconds = ChaptersPipelineConstants.escalatedCallTimeoutSeconds
        escalatedThinking = ChaptersPipelineConstants.escalatedThinking
    }

    var remainingSeconds: Int {
        let remaining = deadline - clock.now()
        guard remaining > 0 else { return 0 }
        return min(Int(remaining.rounded(.down)), runBudgetSeconds)
    }

    func callTimeout(thinking: String) -> Int? {
        let remaining = remainingSeconds
        guard remaining >= floorSeconds else { return nil }
        return min(remaining, thinking == escalatedThinking ? escalatedCapSeconds : baseCapSeconds)
    }

    func backoff(seconds: Int) -> Int? {
        remainingSeconds >= seconds + floorSeconds ? seconds : nil
    }
}

/// The transport ladder for one Chapters & Summary attempt: at most
/// `maxTries` sends, of which timeouts may claim at most
/// `maxTimeoutResends` resends.
struct ChaptersTransportLadder {
    enum Failure: Equatable {
        case timeout
        case fetchError
        case retryableStatus(retryAfterSeconds: Int?)
    }

    enum Step: Equatable {
        case resend(delaySeconds: Int)
        case giveUp(delaySeconds: Int)
    }

    let maxTries: Int
    let maxTimeoutResends: Int
    let maxRetryDelaySeconds: Int
    private(set) var failedTries = 0
    private(set) var timeoutResends = 0

    init(maxTries: Int, maxTimeoutResends: Int, maxRetryDelaySeconds: Int) {
        self.maxTries = maxTries
        self.maxTimeoutResends = maxTimeoutResends
        self.maxRetryDelaySeconds = maxRetryDelaySeconds
    }

    mutating func next(after failure: Failure) -> Step {
        failedTries += 1
        let delay: Int = switch failure {
        case .timeout: 0
        case .fetchError: analysisBackoffSeconds(attempt: failedTries)
        case .retryableStatus(let retryAfter):
            min(retryAfter ?? analysisBackoffSeconds(attempt: failedTries), maxRetryDelaySeconds)
        }
        if failedTries >= maxTries { return .giveUp(delaySeconds: delay) }
        if failure == .timeout {
            if timeoutResends >= maxTimeoutResends { return .giveUp(delaySeconds: delay) }
            timeoutResends += 1
        }
        return .resend(delaySeconds: delay)
    }
}

/// One Chapters & Summary run: one request per episode, coalesced above the
/// threshold, up to the attempt limit with every retry at the escalated
/// thinking level, validated in unit space and again in original ids.
struct ChaptersRunEngine: Sendable {
    let policy: ChaptersSummaryPolicy
    let model: AnalysisModelEntry
    let transport: any AnalysisProviderTransport
    let clock: any AnalysisClock

    private enum AttemptFailure {
        case validation(String)
        case parse(String)
        case transport(AnalysisFailure)
    }

    private enum LadderError: Error {
        case terminal(AnalysisFailure)
        case exhausted(AnalysisFailure, delaySeconds: Int)
        case budget(AnalysisFailure)
    }

    static func failure(_ code: AnalysisFailureCode, status: Int, detail: String? = nil) -> AnalysisFailure {
        AnalysisFailure(feature: .chaptersSummary, code: code, status: status, detail: detail)
    }

    func run(_ request: TranscriptAnalysisRequest) async -> AnalysisOutcome {
        if case .failure(let error) = AnalysisRequestValidation.validate(request, policy: policy) {
            return .failed(Self.failure(
                AnalysisFailureCode(rawValue: error.code) ?? .invalidTranscriptMetadata,
                status: 400
            ))
        }
        var trace: [ChaptersAttemptTrace] = []
        return await runValidated(request, trace: &trace)
    }

    /// The run after request validation, as the service's analysis step.
    func runValidated(
        _ request: TranscriptAnalysisRequest,
        trace: inout [ChaptersAttemptTrace]
    ) async -> AnalysisOutcome {
        let prepared: ChaptersPreparedRequest
        switch ChaptersPreparation.prepare(request, policy: policy) {
        case .failure: return .failed(Self.failure(.transcriptTooLong, status: 400))
        case .success(let value): prepared = value
        }
        let budget = ChaptersRunBudget(clock: clock, policy: policy, model: model)
        let baseLevel = ChaptersCanonicalPayload.baseThinking(
            modelSegmentCount: prepared.modelRequest.segments.count,
            model: model,
            policy: policy
        )
        var warnings: [String] = []
        var lastFailure: AttemptFailure?
        var usage: AnalysisUsage?
        attempts: for attempt in 0..<ChaptersPipelineConstants.analysisAttempts {
            if Task.isCancelled { return .failed(Self.failure(.cancelled, status: 503)) }
            let level = attempt == 0 ? baseLevel : ChaptersPipelineConstants.escalatedThinking
            let isLast = attempt + 1 == ChaptersPipelineConstants.analysisAttempts
            guard budget.callTimeout(thinking: level) != nil else { break }
            let payload = ChaptersCanonicalPayload.payload(
                prepared.modelRequest,
                policy: policy,
                maxOutputTokens: model.maxOutputTokens,
                thinking: level
            )
            let reply: AnalysisProviderReply
            do {
                reply = try await callWithRetry(payload, thinking: level, attempt: attempt, budget: budget)
            } catch {
                switch error {
                case .terminal(let failure):
                    return .failed(failure)
                case .budget(let failure):
                    lastFailure = .transport(failure)
                    break attempts
                case .exhausted(let failure, let delaySeconds):
                    lastFailure = .transport(failure)
                    if isLast { continue attempts }
                    if delaySeconds > 0 {
                        guard let delay = budget.backoff(seconds: delaySeconds) else { break attempts }
                        do {
                            try await clock.sleep(seconds: Double(delay))
                        } catch {
                            return .failed(Self.failure(.cancelled, status: 503))
                        }
                    }
                    warnings.append("\(failure.code.rawValue)_retried_high")
                    continue attempts
                }
            }
            if Task.isCancelled { return .failed(Self.failure(.cancelled, status: 503)) }
            let parsed = switch reply {
            case .geminiBody(let body): ChaptersAnswerParser.parse(geminiBody: body)
            case .answer(let answer): ChaptersAnswerParser.parse(answer: answer)
            }
            usage = AnalysisUsage.combine(usage, parsed.usage)
            warnings.append(contentsOf: parsed.warnings)
            var attemptTrace = ChaptersAttemptTrace(attempt: attempt, thinking: level, payload: payload, parsed: parsed)
            if let output = parsed.output {
                let validated = ChaptersValidator.validateAndRemap(
                    original: request,
                    prepared: prepared,
                    output: output,
                    policy: policy
                )
                attemptTrace.result = validated
                trace.append(attemptTrace)
                switch validated {
                case .success(let analysis):
                    if Task.isCancelled { return .failed(Self.failure(.cancelled, status: 503)) }
                    return .chaptersSummary(TranscriptAnalysisResponse(
                        schemaVersion: 1,
                        requestID: request.requestID,
                        model: model.modelID,
                        policy: policy.policy,
                        chapters: analysis.chapters,
                        summary: analysis.summary,
                        warnings: analysis.warnings + warnings,
                        usage: usage
                    ))
                case .failure(let rejection):
                    if !isLast { warnings.append("invalid_model_output_retried_high:\(rejection.codes)") }
                    lastFailure = .validation(rejection.codes)
                }
            } else {
                trace.append(attemptTrace)
                let failure = parsed.failure ?? ChaptersAnswerParser.malformedModelJSON
                if !isLast { warnings.append("\(failure)_retried_high") }
                lastFailure = .parse(failure)
            }
        }
        switch lastFailure {
        case .validation(let codes):
            return .failed(Self.failure(.invalidModelOutput, status: 502, detail: codes))
        case .parse(let failure):
            return .failed(Self.failure(
                failure == ChaptersAnswerParser.truncated ? .modelOutputTruncated : .invalidModelOutput,
                status: 502
            ))
        case .transport(let failure):
            return .failed(failure)
        case nil:
            return .failed(Self.failure(.timeout, status: 503))
        }
    }

    private func callWithRetry(
        _ payload: JSONValue,
        thinking: String,
        attempt: Int,
        budget: ChaptersRunBudget
    ) async throws(LadderError) -> AnalysisProviderReply {
        let text = JSONWriter.string(payload)
        var ladder = ChaptersTransportLadder(
            maxTries: ChaptersPipelineConstants.transportAttempts,
            maxTimeoutResends: ChaptersPipelineConstants.timeoutResends,
            maxRetryDelaySeconds: ChaptersPipelineConstants.maxRetryDelaySeconds
        )
        var lastError = Self.failure(.timeout, status: 503)
        var sendIndex = 0
        while true {
            guard let timeout = budget.callTimeout(thinking: thinking) else { throw .budget(lastError) }
            let request = AnalysisProviderRequest(
                feature: .chaptersSummary,
                purpose: .chapters(attempt: attempt),
                model: model,
                payload: payload,
                payloadText: text,
                thinking: thinking,
                timeoutSeconds: Double(timeout),
                sendIndex: sendIndex
            )
            sendIndex += 1
            let failure: ChaptersTransportLadder.Failure
            do {
                return try await transport.send(request)
            } catch {
                if Task.isCancelled { throw .terminal(Self.failure(.cancelled, status: 503)) }
                switch error {
                case .retryable(_, let retryAfter):
                    lastError = Self.failure(.retryExhausted, status: 503)
                    failure = .retryableStatus(retryAfterSeconds: retryAfter.map {
                        min(max($0, 0), ChaptersPipelineConstants.maxRetryDelaySeconds)
                    })
                case .quotaExhausted:
                    throw .terminal(Self.failure(.quotaExhausted, status: 503))
                case .rejected(let status):
                    let upstream = status == 429 || (500..<600).contains(status) ? 503 : 502
                    throw .terminal(Self.failure(.providerRejected, status: upstream, detail: "status \(status)"))
                case .timeout:
                    lastError = Self.failure(.timeout, status: 503)
                    failure = .timeout
                case .network:
                    lastError = Self.failure(.network, status: 502)
                    failure = .fetchError
                case .oversizedBody:
                    throw .terminal(Self.failure(.responseOversized, status: 503))
                case .invalidEncoding:
                    throw .terminal(Self.failure(.responseEncoding, status: 503))
                case .notArchived:
                    throw .terminal(Self.failure(.replayMissingReply, status: 0))
                }
            }
            switch ladder.next(after: failure) {
            case .giveUp(let delaySeconds):
                throw .exhausted(lastError, delaySeconds: delaySeconds)
            case .resend(let delaySeconds):
                if delaySeconds > 0 {
                    guard let delay = budget.backoff(seconds: delaySeconds) else { throw .budget(lastError) }
                    do {
                        try await clock.sleep(seconds: Double(delay))
                    } catch {
                        throw .terminal(Self.failure(.cancelled, status: 503))
                    }
                }
            }
        }
    }
}
