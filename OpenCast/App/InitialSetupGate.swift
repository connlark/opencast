import Foundation

final class InitialSetupGate {
    private(set) var isComplete = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    var waiterCount: Int {
        waiters.count
    }

    func complete() {
        guard !isComplete else {
            return
        }
        isComplete = true
        let pendingWaiters = waiters.values
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }

    func wait() async {
        guard !isComplete else {
            return
        }

        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !isComplete, !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                waiters[waiterID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(id: waiterID)
            }
        }
    }

    private func cancelWaiter(id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}
