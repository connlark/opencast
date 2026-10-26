import Foundation
import OpenCastAnalysis

/// Sends canonical payloads through the opencast-funded trial service,
/// which adds opencast's Gemini key and forwards the request unchanged. The
/// transport holds no key: each window goes out as the service's wrapper
/// (`feature`, `run_id`, `window_index`, the Gemini body as `request`, and
/// the call's own budget as `timeout_seconds`) through an
/// ``AnalysisTrialProxyExchange``. A refusal from the service itself (a
/// body whose `error` is a string) is read from its closed vocabulary;
/// every other reply is Gemini's and is read as the Gemini transport reads
/// it. A busy service (another window of this install is in flight) is
/// waited out inside the send, a fresh post each time, and never spends the
/// pipeline's retries.
public struct TrialProxyAnalysisTransport: AnalysisProviderTransport {
    public static let analyzePath = "/v1/trial/analyze"
    public static let statusPath = "/v1/trial/status"
    /// The largest wrapper the service accepts, in bytes.
    public static let maximumWrapperBytes = 1_572_864
    /// The highest `window_index` the service accepts.
    public static let maximumWindowIndex = 1_023
    /// The longest `timeout_seconds` the service accepts.
    public static let maximumTimeoutSeconds = 600
    /// Posts after the first that a busy service may ask for in one send.
    public static let maximumBusyRetries = 8
    /// The longest busy wait the service asks for.
    public static let maximumBusyWaitSeconds = 10

    public let runID: String
    private let proxy: any AnalysisTrialProxyExchange
    private let clock: any AnalysisClock
    private let exchange: AnalysisProviderExchange

    /// - Parameters:
    ///   - runID: The run record's id: 1 to 64 of `[A-Za-z0-9_-]`. Any other
    ///     id refuses every send before anything is sent.
    ///   - observer: Receives a record of every send.
    public init(
        runID: String,
        exchange proxy: any AnalysisTrialProxyExchange,
        observer: (any AnalysisProviderSendObserver)? = nil,
        logger: RedactingLogger = RedactingLogger(),
        clock: any AnalysisClock = AnalysisSystemClock()
    ) {
        self.runID = runID
        self.proxy = proxy
        self.clock = clock
        exchange = AnalysisProviderExchange(
            provider: .google,
            client: TrialProxyUnusedHTTPClient(),
            pacer: nil,
            observer: observer,
            logger: logger,
            clock: clock,
            verifier: SecretVerifier(secrets: [])
        )
    }

    public func send(_ request: AnalysisProviderRequest) async throws(AnalysisTransportError) -> AnalysisProviderReply {
        try await exchange.send(
            request,
            refusal: refusal(for: request),
            perform: { (deadline, waits) throws(AnalysisHTTPFailure) -> AnalysisHTTPResponse in
                try await post(request, deadline: deadline, waits: waits)
            },
            interpret: GeminiAnalysisTransport.interpret,
            classify: Self.classify
        )
    }

    /// Why a request cannot go to the service at all; `nil` when it can.
    /// The size check uses the widest `timeout_seconds`, so no later post of
    /// the same request can be larger.
    func refusal(for request: AnalysisProviderRequest) -> AnalysisProviderErrorClassification? {
        guard Self.isValidRunID(runID),
              (0...Self.maximumWindowIndex).contains(request.purpose.windowIndex ?? 0)
        else {
            return AnalysisProviderErrorClassification(transport: .rejected(status: 0), listener: .requestRejected)
        }
        let widest = Self.wrapper(request, runID: runID, timeoutSeconds: Double(Self.maximumTimeoutSeconds))
        guard widest.utf8.count <= Self.maximumWrapperBytes else {
            return AnalysisProviderErrorClassification(transport: .rejected(status: 413), listener: .requestRejected)
        }
        return nil
    }

    /// Posts the window, then again after each busy wait while the service
    /// asks for one, the retries last, and the wait and one more second fit
    /// before the deadline. The last reply goes back as it is.
    private func post(
        _ request: AnalysisProviderRequest,
        deadline: Double,
        waits: AnalysisSendWaitMeter
    ) async throws(AnalysisHTTPFailure) -> AnalysisHTTPResponse {
        var busyRetries = 0
        while true {
            let remaining = deadline - clock.now()
            guard remaining > 0 else { throw .timeout }
            let response = try await proxy.post(
                path: Self.analyzePath,
                payloadText: Self.wrapper(request, runID: runID, timeoutSeconds: remaining),
                timeoutSeconds: remaining,
                maximumBodyBytes: AnalysisProviderLimits.maxResponseBytes
            )
            guard busyRetries < Self.maximumBusyRetries,
                  let wait = Self.busyWaitSeconds(response),
                  clock.now() + Double(wait) + 1 < deadline
            else {
                return response
            }
            busyRetries += 1
            let started = clock.now()
            do {
                try await clock.sleep(seconds: Double(wait))
            } catch {
                waits.add(clock.now() - started)
                throw .network
            }
            waits.add(clock.now() - started)
        }
    }

    /// The service's wrapper for one post. `request` is the canonical
    /// payload as a JSON object, written by the same writer that wrote
    /// `payloadText`, so its bytes are the Gemini body the direct route
    /// sends. `timeout_seconds` is the whole seconds left, 1 to 600.
    static func wrapper(_ request: AnalysisProviderRequest, runID: String, timeoutSeconds: Double) -> String {
        let seconds = timeoutSeconds.isNaN
            ? 1
            : Int(min(max(timeoutSeconds.rounded(.down), 1), Double(maximumTimeoutSeconds)))
        return JSONWriter.string(.object([
            JSONMember("feature", .string(request.feature.rawValue)),
            JSONMember("run_id", .string(runID)),
            JSONMember("window_index", .integer(request.purpose.windowIndex ?? 0)),
            JSONMember("request", request.payload),
            JSONMember("timeout_seconds", .integer(seconds)),
        ]))
    }

    static func isValidRunID(_ runID: String) -> Bool {
        (1...64).contains(runID.utf8.count) && runID.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || byte == 0x5F || byte == 0x2D
        }
    }

    /// The wait a busy refusal asks for (its body's `retry_after_seconds`,
    /// else its `Retry-After`, else the longest), at least a second and at
    /// most ``maximumBusyWaitSeconds``; `nil` for any other reply.
    static func busyWaitSeconds(_ response: AnalysisHTTPResponse) -> Int? {
        guard response.status == 409,
              let text = String(validating: response.body, as: UTF8.self),
              let refusal = TrialProxyRefusal(body: text),
              refusal.code == .trialBusy
        else {
            return nil
        }
        let asked = refusal.retryAfterSeconds ?? response.retryAfterSeconds ?? maximumBusyWaitSeconds
        return min(max(asked, 1), maximumBusyWaitSeconds)
    }

    /// Classifies a non-2xx reply: the service's own refusals by their code,
    /// everything else (Gemini's errors, passed through) by the Gemini table.
    public static func classify(status: Int, retryAfter: String?, body: String) -> AnalysisProviderErrorClassification {
        guard let refusal = TrialProxyRefusal(body: body) else {
            return GeminiProviderErrors.classify(status: status, retryAfter: retryAfter, body: body)
        }
        let rejected = AnalysisTransportError.rejected(status: status)
        switch refusal.code {
        case .trialExhausted:
            return AnalysisProviderErrorClassification(transport: rejected, listener: .trialExhausted)
        case .trialRunBound:
            return AnalysisProviderErrorClassification(transport: rejected, listener: .trialRunBound)
        case .trialPaused:
            return AnalysisProviderErrorClassification(transport: rejected, listener: .trialPaused)
        case .trialUnavailable where refusal.retryAfterSeconds != nil:
            // The service's token count failed: nothing was reserved or
            // charged, so the window may be sent again after the wait.
            return AnalysisProviderErrorClassification(
                transport: .retryable(status: 503, retryAfterSeconds: maximumBusyWaitSeconds),
                listener: .trialUnavailable
            )
        case .trialUnavailable, .trialDisabled:
            return AnalysisProviderErrorClassification(transport: rejected, listener: .trialUnavailable)
        case .trialBusy:
            return AnalysisProviderErrorClassification(
                transport: .retryable(status: 409, retryAfterSeconds: maximumBusyWaitSeconds),
                listener: .overloaded
            )
        case .providerTimeout:
            return AnalysisProviderErrorClassification(transport: .timeout, listener: .timeout)
        case .providerUnreachable:
            return AnalysisProviderErrorClassification(transport: .network, listener: .unreachable)
        case .providerBodyTooLarge:
            return AnalysisProviderErrorClassification(transport: .oversizedBody, listener: .malformedAnswer)
        case .other:
            return AnalysisProviderErrorClassification(transport: rejected, listener: .requestRejected)
        }
    }
}

extension TrialProxyAnalysisTransport: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "TrialProxyAnalysisTransport" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// A refusal the trial service answers itself: `{"error": "<code>"}` with a
/// string `error`, optionally `retry_after_seconds`. Gemini's errors carry
/// an object there and are not refusals.
struct TrialProxyRefusal: Sendable, Hashable {
    enum Code: Sendable, Hashable {
        case trialExhausted
        case trialRunBound
        case trialPaused
        case trialUnavailable
        case trialDisabled
        case trialBusy
        case providerTimeout
        case providerUnreachable
        case providerBodyTooLarge
        /// Any other code: a request the service refused (`request_invalid`,
        /// `payload_too_large`, an App Attest code the app's recovery did not
        /// clear, an operator-only code). A device bug, never retried.
        case other

        init(_ code: String) {
            self = switch code {
            case "trial_exhausted": .trialExhausted
            case "trial_run_bound": .trialRunBound
            case "trial_paused": .trialPaused
            case "trial_unavailable": .trialUnavailable
            case "trial_disabled": .trialDisabled
            case "trial_busy": .trialBusy
            case "provider_timeout": .providerTimeout
            case "provider_unreachable": .providerUnreachable
            case "provider_body_too_large": .providerBodyTooLarge
            default: .other
            }
        }
    }

    var code: Code
    /// Whole seconds, when the refusal carries a non-negative integer.
    var retryAfterSeconds: Int?

    init?(body: String) {
        guard !ProviderJSON.refusesBody(body),
              let root = ProviderJSON.parse(body),
              let code = root["error"]?.stringValue
        else {
            return nil
        }
        self.code = Code(code)
        retryAfterSeconds = ProviderJSON.count(root["retry_after_seconds"])
            .map { Int(min($0, UInt64(GeminiErrorClassifier.maxRetryAfterSeconds))) }
    }
}

/// The trial transport supplies its own exchange; the shared send path's
/// client is never called.
private struct TrialProxyUnusedHTTPClient: AnalysisHTTPClient {
    func send(
        _ request: AnalysisHTTPRequest,
        timeoutSeconds: Double,
        maximumBodyBytes: Int
    ) async throws(AnalysisHTTPFailure) -> AnalysisHTTPResponse {
        throw .network
    }
}
