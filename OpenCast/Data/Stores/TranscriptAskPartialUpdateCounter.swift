import Synchronization

/// Counts streamed partial updates for a turn's report.
nonisolated final class TranscriptAskPartialUpdateCounter: Sendable {
    private let value = Mutex(0)

    var count: Int {
        value.withLock { $0 }
    }

    func increment() {
        value.withLock { $0 += 1 }
    }
}
