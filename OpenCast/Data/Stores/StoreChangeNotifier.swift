import Foundation

final class StoreChangeNotifier {
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private(set) var sequence = 0

    isolated deinit {
        resumeAllWaiters()
    }

    func notify() {
        sequence += 1
        resumeAllWaiters()
    }

    func wait(after observedSequence: Int) async throws {
        guard sequence == observedSequence else {
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard sequence == observedSequence, !Task.isCancelled else {
                    continuation.resume()
                    return
                }

                waiters[waiterID] = continuation
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(waiterID)
            }
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        waiters.removeValue(forKey: waiterID)?.resume()
    }

    private func resumeAllWaiters() {
        let continuations = Array(waiters.values)
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}
