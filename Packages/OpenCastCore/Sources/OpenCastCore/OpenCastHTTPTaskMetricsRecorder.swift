import Foundation

public final class OpenCastHTTPTaskMetricsRecorder: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var storedSummaries: [OpenCastHTTPTaskMetricsSummary] = []
    private var storedTotalCount = 0

    public init(capacity: Int = 250) {
        self.capacity = max(capacity, 0)
        super.init()
    }

    public var summaries: [OpenCastHTTPTaskMetricsSummary] {
        lock.withLock {
            storedSummaries
        }
    }

    public var totalCount: Int {
        lock.withLock {
            storedTotalCount
        }
    }

    public func clear() {
        lock.withLock {
            storedSummaries.removeAll()
            storedTotalCount = 0
        }
    }

    public func record(_ summary: OpenCastHTTPTaskMetricsSummary) {
        lock.withLock {
            storedTotalCount += 1
            guard capacity > 0 else {
                return
            }

            storedSummaries.append(summary)
            if storedSummaries.count > capacity {
                storedSummaries.removeFirst(storedSummaries.count - capacity)
            }
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        let summary = OpenCastHTTPTaskMetricsSummary(
            duration: metrics.taskInterval.duration,
            redirectCount: metrics.redirectCount,
            transactionCount: metrics.transactionMetrics.count
        )
        record(summary)
    }
}
