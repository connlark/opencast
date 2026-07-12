import Foundation

nonisolated final class AdFreePassCancellationSource: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var requestCount = 0

    func start(_ task: Task<Void, Never>) {
        lock.withLock {
            self.task = task
            requestCount = 0
        }
    }

    func clearTask() {
        lock.withLock {
            task = nil
        }
    }

    func cancel() {
        let taskToCancel = lock.withLock {
            requestCount += 1
            return task
        }
        taskToCancel?.cancel()
    }

    var cancellationRequestCount: Int {
        lock.withLock {
            requestCount
        }
    }
}

nonisolated final class AdFreePassOnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasPassed = false

    func pass() -> Bool {
        lock.withLock {
            guard !hasPassed else {
                return false
            }

            hasPassed = true
            return true
        }
    }
}

private extension NSLock {
    nonisolated func withLock<Result>(_ work: () -> Result) -> Result {
        lock()
        defer {
            unlock()
        }
        return work()
    }
}
