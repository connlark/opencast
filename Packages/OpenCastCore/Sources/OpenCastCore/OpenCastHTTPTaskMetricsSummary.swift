import Foundation

public struct OpenCastHTTPTaskMetricsSummary: Sendable, Equatable {
    public var duration: TimeInterval
    public var redirectCount: Int
    public var transactionCount: Int

    public init(duration: TimeInterval, redirectCount: Int, transactionCount: Int) {
        self.duration = duration
        self.redirectCount = redirectCount
        self.transactionCount = transactionCount
    }
}
