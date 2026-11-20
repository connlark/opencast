import OpenCastAnalysis
import Synchronization

/// `input` includes `cached` and `write`; `output` includes `reasoning`.
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

/// Never carries provider text, a header or the key: every field is a closed value, a number or
/// a scrubbed model id, so an observer that sees a record before any logger has nothing to scrub.
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
    public var status: Int?
    public var finishReason: AnalysisFinishReason?
    public var failure: AnalysisProviderFailure?
    public var cancelled: Bool
    public var freeTier: Bool
    public var usage: AnalysisBilledUsage?
    public var pacedSeconds: Double
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
        freeTier: Bool = false,
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
        self.freeTier = freeTier
        self.usage = usage
        self.pacedSeconds = pacedSeconds
        self.exchangeSeconds = exchangeSeconds
    }
}

public protocol AnalysisProviderSendObserver: Sendable {
    func record(_ send: AnalysisProviderSendRecord)
}

/// In completion order.
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
