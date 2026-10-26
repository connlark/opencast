/// One model request the pipeline asks a transport to send.
public struct AnalysisProviderRequest: Sendable {
    public enum Purpose: Sendable, Hashable {
        /// An ad-detection window's first request.
        case adWindow(index: Int)
        /// The one corrective request for an ad-detection window.
        case adRepair(index: Int)
        /// A Chapters & Summary request; `attempt` counts from 0.
        case chapters(attempt: Int)
    }

    public var feature: AnalysisFeature
    public var purpose: Purpose
    public var model: AnalysisModelEntry
    /// The provider-neutral payload in Gemini `generateContent` shape.
    public var payload: JSONValue
    /// `payload` serialized; Gemini transports send these exact bytes.
    public var payloadText: String
    /// The thinking level for this request, which a transport maps to its
    /// provider's control. It equals the payload's `thinkingLevel` when the
    /// payload carries one.
    public var thinking: String?
    /// The deadline for the whole exchange, send and body read.
    public var timeoutSeconds: Double
    /// 0 for the first send of this request, then 1, 2, … for resends.
    public var sendIndex: Int
}

/// An answer a transport has reduced to the provider-neutral form: what a
/// single-candidate Gemini response would carry.
public struct AnalysisProviderAnswer: Sendable, Hashable {
    /// The answer's non-thought text parts, in order.
    public var texts: [String]
    /// In Gemini's vocabulary: `STOP` for a complete answer, `MAX_TOKENS`
    /// for a length cut-off, anything else (such as `SAFETY`) for a refusal.
    public var finishReason: String?
    public var usage: AnalysisUsage?

    public init(texts: [String], finishReason: String?, usage: AnalysisUsage?) {
        self.texts = texts
        self.finishReason = finishReason
        self.usage = usage
    }
}

/// A successful (2xx) provider exchange.
public enum AnalysisProviderReply: Sendable, Hashable {
    /// A Gemini `generateContent` body, parsed exactly as the services do.
    case geminiBody(String)
    /// A provider answer already reduced by its transport.
    case answer(AnalysisProviderAnswer)
}

/// Why a send produced no usable reply.
public enum AnalysisTransportError: Error, Sendable, Hashable {
    /// The provider asked to retry: a 5xx, or a 429 that is not a hard quota.
    case retryable(status: Int, retryAfterSeconds: Int?)
    /// The key's quota, billing or prepaid credit is exhausted.
    case quotaExhausted
    /// Any other non-2xx status; retrying will not help.
    case rejected(status: Int)
    /// The deadline passed before the exchange completed.
    case timeout
    /// The request never reached the provider or the body stream failed.
    case network
    /// The provider's body exceeded the size the pipeline accepts.
    case oversizedBody
    /// The provider's body was not UTF-8.
    case invalidEncoding
    /// A replay transport holds no archived answer for this request.
    case notArchived
}

/// Sends canonical payloads to one provider. Implementations hold the key,
/// map the canonical payload to the provider's wire format, enforce the
/// timeout, and never log a header or keep a body beyond the call.
public protocol AnalysisProviderTransport: Sendable {
    func send(_ request: AnalysisProviderRequest) async throws(AnalysisTransportError) -> AnalysisProviderReply
}

/// Time for the run budget and the pauses between sends. Tests and replays
/// use a virtual clock.
public protocol AnalysisClock: Sendable {
    /// Seconds since an arbitrary fixed origin.
    func now() -> Double
    func sleep(seconds: Double) async throws
}

/// The wall clock.
public struct AnalysisSystemClock: AnalysisClock {
    public init() {}

    public func now() -> Double {
        let components = Self.origin.duration(to: .now).components
        return Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }

    public func sleep(seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    private static let origin = ContinuousClock.now
}
