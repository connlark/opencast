public struct AnalysisProviderRequest: Sendable {
    public enum Purpose: Sendable, Hashable {
        case adWindow(index: Int)
        case adRepair(index: Int)
        /// `attempt` counts from 0.
        case chapters(attempt: Int)
    }

    public var feature: AnalysisFeature
    public var purpose: Purpose
    public var model: AnalysisModelEntry
    /// The provider-neutral payload in Gemini `generateContent` shape.
    public var payload: JSONValue
    /// `payload` serialized; Gemini transports send these exact bytes.
    public var payloadText: String
    /// Equals the payload's `thinkingLevel` whenever the payload carries one.
    public var thinking: String?
    /// The deadline for the whole exchange, send and body read.
    public var timeoutSeconds: Double
    /// 0 for the first send of this request, then 1, 2, … for resends.
    public var sendIndex: Int
}

/// What a single-candidate Gemini response would carry.
public struct AnalysisProviderAnswer: Sendable, Hashable {
    /// The answer's non-thought text parts, in order.
    public var texts: [String]
    /// Gemini's vocabulary: `STOP`, `MAX_TOKENS` for a length cut-off, anything else a refusal.
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
    case geminiBody(String)
    case answer(AnalysisProviderAnswer)
}

public enum AnalysisTransportError: Error, Sendable, Hashable {
    /// The provider asked to retry: a 5xx, or a 429 that is not a hard quota.
    case retryable(status: Int, retryAfterSeconds: Int?)
    /// The key's quota, billing or prepaid credit is exhausted.
    case quotaExhausted
    /// Any other non-2xx status; retrying will not help.
    case rejected(status: Int)
    case timeout
    /// The request never reached the provider or the body stream failed.
    case network
    case oversizedBody
    case invalidEncoding
    case notArchived
}

/// Implementations enforce the request's timeout and never log a header or keep a body beyond
/// the call.
public protocol AnalysisProviderTransport: Sendable {
    func send(_ request: AnalysisProviderRequest) async throws(AnalysisTransportError) -> AnalysisProviderReply
}

public protocol AnalysisClock: Sendable {
    /// Seconds since an arbitrary fixed origin.
    func now() -> Double
    func sleep(seconds: Double) async throws
}

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
