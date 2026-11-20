import Synchronization

nonisolated final class TranscriptAskPartialUpdateCounter: Sendable {
    private let value = Mutex(0)

    var count: Int {
        value.withLock { $0 }
    }

    func increment() {
        value.withLock { $0 += 1 }
    }
}
