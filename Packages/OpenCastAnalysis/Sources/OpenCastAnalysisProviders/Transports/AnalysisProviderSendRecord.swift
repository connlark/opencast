import OpenCastAnalysis
import Synchronization

/// Token usage as the provider bills it: input (cached and cache-write
/// tokens included), cached input, cache writes, output (reasoning included)
/// and the reasoning share of the output.
public struct AnalysisBilledUsage: Sendable, Hashable, Codable {
    public var input: UInt64
    public var cached: UInt64
    public var write: UInt64
    public var output: UInt64
    public var reasoning: UInt64

    public init(input: UInt64, cached: UInt64, write: UInt64, output: UInt64, reasoning: UInt64) {
        self.input = input
        self.cached = cached
        self.write = write
        self.output = output
        self.reasoning = reasoning
    }
}

/// What one provider send did, for the run record and diagnostics. Never
/// carries provider text, a header or the key: every field is a closed
/// value or a number, and the model id is the entry's, kept only when it is
/// 1 to 64 of `[A-Za-z0-9._:-]` (``invalidModelID`` otherwise), so an
/// observer that sees a record before any logger sees nothing to scrub.
public struct AnalysisProviderSendRecord: Sendable, Hashable {
    public static let invalidModelID = "invalid_model_id"

    static func scrubbedModelID(_ modelID: String) -> String {
        let allowed = (1...64).contains(modelID.utf8.count) && modelID.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || byte == 0x2E || byte == 0x5F || byte == 0x3A || byte == 0x2D
        }
        return allowed ? modelID : invalidModelID
    }

    public var provider: AnalysisProvider
    public var modelID: String
    public var feature: AnalysisFeature
    public var purpose: AnalysisProviderRequest.Purpose
    public var sendIndex: Int
    /// The HTTP status, when a response arrived.
    public var status: Int?
    /// How the answer ended, when a 2xx arrived; a closed set, never
    /// provider text.
    public var finishReason: AnalysisFinishReason?
    /// Why the send failed; `nil` when a 2xx answer arrived or the run
    /// cancelled the send.
    public var failure: AnalysisProviderFailure?
    /// The run cancelled the send (another window had already failed, or
    /// the caller stopped the run); the provider said nothing about it.
    public var cancelled: Bool
    public var usage: AnalysisBilledUsage?
    /// Seconds spent waiting for the key's pacer before sending.
    public var pacedSeconds: Double
    /// Seconds from admission to the end of the body read.
    public var exchangeSeconds: Double

    public init(
        provider: AnalysisProvider,
        modelID: String,
        feature: AnalysisFeature,
        purpose: AnalysisProviderRequest.Purpose,
        sendIndex: Int,
        status: Int?,
        finishReason: AnalysisFinishReason?,
        failure: AnalysisProviderFailure?,
        cancelled: Bool = false,
        usage: AnalysisBilledUsage?,
        pacedSeconds: Double,
        exchangeSeconds: Double
    ) {
        self.provider = provider
        self.modelID = Self.scrubbedModelID(modelID)
        self.feature = feature
        self.purpose = purpose
        self.sendIndex = sendIndex
        self.status = status
        self.finishReason = finishReason
        self.failure = failure
        self.cancelled = cancelled
        self.usage = usage
        self.pacedSeconds = pacedSeconds
        self.exchangeSeconds = exchangeSeconds
    }
}

/// Receives a record of every send a transport makes.
public protocol AnalysisProviderSendObserver: Sendable {
    func record(_ send: AnalysisProviderSendRecord)
}

/// The sends of one run, in completion order. The app resolves the
/// listener-facing failure from them with ``AnalysisProviderFailure/resolve(_:sends:)``.
public final class AnalysisProviderSendLog: AnalysisProviderSendObserver {
    private let storage = Mutex<[AnalysisProviderSendRecord]>([])

    public init() {}

    public func record(_ send: AnalysisProviderSendRecord) {
        storage.withLock { $0.append(send) }
    }

    public var sends: [AnalysisProviderSendRecord] {
        storage.withLock { $0 }
    }
}
