import Foundation
import OpenCastAnalysis
import Synchronization

/// What a provider transport made of a 2xx body.
struct AnalysisProviderInterpretation: Sendable {
    var reply: AnalysisProviderReply
    var finishReason: AnalysisFinishReason?
    var usage: AnalysisBilledUsage?
}

/// The send path both direct transports share: pace on the key, run the
/// exchange inside the request's deadline, classify failures once for the
/// pipeline and the listener, and record and log what happened without any
/// body, header or key.
struct AnalysisProviderExchange: Sendable {
    let provider: AnalysisProvider
    let client: any AnalysisHTTPClient
    let pacer: AnalysisKeyPacer?
    let observer: (any AnalysisProviderSendObserver)?
    let logger: RedactingLogger
    let clock: any AnalysisClock
    /// The transport's key, for the check every record passes before an
    /// observer or the logger sees it.
    let verifier: SecretVerifier
    /// Runs once the pacer admits a send, right before it leaves.
    var preDispatch: AnalysisPreDispatchCheck? = nil

    func send(
        _ request: AnalysisProviderRequest,
        http: AnalysisHTTPRequest?,
        interpret: (String) -> AnalysisProviderInterpretation,
        classify: (_ status: Int, _ retryAfter: String?, _ body: String) -> AnalysisProviderErrorClassification
    ) async throws(AnalysisTransportError) -> AnalysisProviderReply {
        // The canonical payload or the model id could not be mapped to a
        // request for this provider; nothing is sent.
        let refusal = http == nil ? AnalysisProviderErrorClassification(transport: .rejected(status: 0), listener: .requestRejected) : nil
        return try await send(
            request,
            refusal: refusal,
            perform: { (deadline, _) throws(AnalysisHTTPFailure) -> AnalysisHTTPResponse in
                guard let http else { throw AnalysisHTTPFailure.network }
                return try await client.send(
                    http,
                    timeoutSeconds: deadline - clock.now(),
                    maximumBodyBytes: AnalysisProviderLimits.maxResponseBytes
                )
            },
            interpret: interpret,
            classify: classify
        )
    }

    /// The send path with the exchange itself supplied by the transport.
    /// `refusal`, when set, fails the send before anything is paced or sent;
    /// `preDispatch`, once the pacer admits it, can still refuse it unsent.
    /// `perform` runs once the pacer admits the send, with the send's
    /// deadline in clock time (at least one tick away); time it reports to
    /// the meter counts as paced, not as exchange time.
    func send(
        _ request: AnalysisProviderRequest,
        refusal: AnalysisProviderErrorClassification?,
        perform: (_ deadline: Double, _ waits: AnalysisSendWaitMeter) async throws(AnalysisHTTPFailure) -> AnalysisHTTPResponse,
        interpret: (String) -> AnalysisProviderInterpretation,
        classify: (_ status: Int, _ retryAfter: String?, _ body: String) -> AnalysisProviderErrorClassification
    ) async throws(AnalysisTransportError) -> AnalysisProviderReply {
        let start = clock.now()
        let deadline = start + AnalysisProviderLimits.waitSeconds(request.timeoutSeconds)
        var outcome = Outcome(request: request, provider: provider)
        if let refusal {
            throw finish(&outcome, refusal)
        }
        if let pacer {
            switch await pacer.admit(deadline: deadline) {
            case .admitted(let waited):
                outcome.pacedSeconds = waited
            case .deadlinePassed:
                outcome.pacedSeconds = clock.now() - start
                let listener: AnalysisProviderFailure = await pacer.isSerial ? .rateLimited : .timeout
                throw finish(&outcome, .init(transport: .timeout, listener: listener))
            case .cancelled:
                throw finish(&outcome, .init(.network))
            }
        }
        // After admission, so what the send waited for cannot outlast it.
        if let preDispatch, let refusal = await preDispatch() {
            await pacer?.release()
            throw finish(&outcome, refusal)
        }
        let admitted = clock.now()
        let waits = AnalysisSendWaitMeter()
        let response: AnalysisHTTPResponse
        do throws(AnalysisHTTPFailure) {
            guard deadline - admitted > 0 else { throw AnalysisHTTPFailure.timeout }
            response = try await perform(deadline, waits)
        } catch {
            await pacer?.release()
            outcome.note(exchangeFrom: admitted, to: clock.now(), waits: waits.seconds)
            throw finish(&outcome, .init(error))
        }
        outcome.note(exchangeFrom: admitted, to: clock.now(), waits: waits.seconds)
        outcome.status = response.status
        // Like the services: the body must be UTF-8 whatever the status.
        guard let text = String(validating: response.body, as: UTF8.self) else {
            await pacer?.release()
            throw finish(&outcome, .invalidEncoding)
        }
        guard (200..<300).contains(response.status) else {
            let classification = classify(response.status, response.retryAfter, text)
            if classification.listener == .rateLimited, case .retryable(_, let retryAfter) = classification.transport {
                // Noted in the same step that frees the slot, so no queued
                // request starts before the cooldown applies.
                await pacer?.release(rateLimited: true, retryAfterSeconds: retryAfter)
                logger.log("pacing provider=\(provider.rawValue) serial=true retry_after=\(retryAfter.map(String.init) ?? "none")")
            } else {
                await pacer?.release()
            }
            throw finish(&outcome, classification)
        }
        await pacer?.release()
        let interpretation = interpret(text)
        outcome.finishReason = interpretation.finishReason
        outcome.usage = interpretation.usage
        record(outcome, failure: nil)
        return interpretation.reply
    }

    struct Outcome {
        var request: AnalysisProviderRequest
        var provider: AnalysisProvider
        var status: Int?
        var finishReason: AnalysisFinishReason?
        var usage: AnalysisBilledUsage?
        var pacedSeconds = 0.0
        var exchangeSeconds = 0.0

        /// Splits the time from admission to `end` into the waits the
        /// exchange reported (paced) and the exchange itself.
        mutating func note(exchangeFrom admitted: Double, to end: Double, waits: Double) {
            let waited = min(max(waits, 0), max(end - admitted, 0))
            pacedSeconds += waited
            exchangeSeconds = end - admitted - waited
        }
    }

    /// Records a failed send. A send the run cancelled is recorded as
    /// cancelled, with no listener-facing failure: the provider said nothing.
    private func finish(_ outcome: inout Outcome, _ classification: AnalysisProviderErrorClassification) -> AnalysisTransportError {
        if Task.isCancelled, outcome.status == nil {
            record(outcome, failure: nil, cancelled: true)
        } else {
            record(outcome, failure: classification.listener)
        }
        return classification.transport
    }

    private func record(_ outcome: Outcome, failure: AnalysisProviderFailure?, cancelled: Bool = false) {
        let request = outcome.request
        let send = AnalysisProviderSendRecord(
            provider: provider,
            modelID: Self.observableModelID(request.model.modelID, verifier: verifier),
            feature: request.feature,
            purpose: request.purpose,
            sendIndex: request.sendIndex,
            status: outcome.status,
            finishReason: outcome.finishReason,
            failure: failure,
            cancelled: cancelled,
            usage: outcome.usage,
            pacedSeconds: outcome.pacedSeconds,
            exchangeSeconds: outcome.exchangeSeconds
        )
        observer?.record(send)
        logger.log(Self.line(send))
    }

    /// The model id a record may carry: the charset- and length-checked id,
    /// unless it holds the key or a key shape, then the fixed sentinel.
    static func observableModelID(_ modelID: String, verifier: SecretVerifier) -> String {
        let scrubbed = AnalysisProviderSendRecord.scrubbedModelID(modelID)
        return verifier.verifyAppText(scrubbed) == .clean ? scrubbed : AnalysisProviderSendRecord.invalidModelID
    }

    static func line(_ send: AnalysisProviderSendRecord) -> String {
        var parts = [
            "send provider=\(send.provider.rawValue)",
            "model=\(send.modelID)",
            "feature=\(send.feature.rawValue)",
            "purpose=\(purposeName(send.purpose))",
            "send_index=\(send.sendIndex)",
            "status=\(send.status.map(String.init) ?? "none")",
        ]
        if send.cancelled {
            parts.append("outcome=cancelled")
        } else if let failure = send.failure {
            parts.append("outcome=failed class=\(failure.rawValue)")
        } else {
            parts.append("outcome=answered finish=\(send.finishReason?.rawValue ?? "none")")
        }
        if let usage = send.usage {
            parts.append("input=\(usage.input) cached=\(usage.cached) output=\(usage.output) reasoning=\(usage.reasoning)")
        }
        parts.append("paced_ms=\(milliseconds(send.pacedSeconds)) exchange_ms=\(milliseconds(send.exchangeSeconds))")
        return parts.joined(separator: " ")
    }

    static func purposeName(_ purpose: AnalysisProviderRequest.Purpose) -> String {
        switch purpose {
        case .adWindow(let index): "ad_window_\(index)"
        case .adRepair(let index): "ad_repair_\(index)"
        case .chapters(let attempt): "chapters_attempt_\(attempt)"
        }
    }

    private static func milliseconds(_ seconds: Double) -> Int {
        seconds.isFinite ? Int((max(seconds, 0) * 1000).rounded()) : 0
    }
}

/// The waits an exchange spends inside its own send (a busy trial service's
/// retry delay), which the send record counts as paced time.
final class AnalysisSendWaitMeter: Sendable {
    private let total = Mutex(0.0)

    func add(_ seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        total.withLock { $0 += seconds }
    }

    var seconds: Double { total.withLock { $0 } }
}

extension AnalysisProviderExchange {
    /// A count or key-test call: unpaced, outside any run, with the
    /// auxiliary deadline.
    func auxiliary(_ http: AnalysisHTTPRequest) async -> Result<(status: Int, retryAfter: String?, text: String), AnalysisProviderErrorClassification> {
        do throws(AnalysisHTTPFailure) {
            let response = try await client.send(
                http,
                timeoutSeconds: AnalysisProviderLimits.auxiliaryCallTimeoutSeconds,
                maximumBodyBytes: AnalysisProviderLimits.maxResponseBytes
            )
            guard let text = String(validating: response.body, as: UTF8.self) else { return .failure(.invalidEncoding) }
            return .success((response.status, response.retryAfter, text))
        } catch {
            return .failure(.init(error))
        }
    }
}
