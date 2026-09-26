import Foundation

nonisolated final class AdFreePassCancellationSource: @unchecked Sendable {
    /// Why the pass task was cancelled. Only a user request may cancel a
    /// remote server job; every other reason parks it for re-attach.
    enum Reason: Equatable, Sendable {
        case userRequest
        case sessionExpiration
        case reset
    }

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var requestCount = 0
    private var lastReason: Reason?

    func start(_ task: Task<Void, Never>) {
        lock.withLock {
            self.task = task
            requestCount = 0
            lastReason = nil
        }
    }

    func clearTask() {
        lock.withLock {
            task = nil
        }
    }

    func cancel(reason: Reason) {
        let taskToCancel = lock.withLock {
            requestCount += 1
            lastReason = reason
            return task
        }
        taskToCancel?.cancel()
    }

    var cancellationRequestCount: Int {
        lock.withLock {
            requestCount
        }
    }

    var lastCancellationReason: Reason? {
        lock.withLock {
            lastReason
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
