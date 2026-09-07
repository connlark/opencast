import Foundation

/// Superseding a reload may discard its snapshot, but its caller must still
/// wait for a published library before restoring playback or pruning history.
/// A canceled loader asks one surviving waiter to replace it; canceling an
/// individual waiter only removes that waiter.
final class LibraryReloadCompletion {
    enum WaitResult {
        case published
        case replacementRequired(cancelledGeneration: Int)
        case invalidated
    }

    private enum Outcome {
        case published
        case failed(any Error)
        case replacementRequired(cancelledGeneration: Int)
        case invalidated
    }

    private var generation = 0
    private var outcome: Outcome? = .published
    private var waiters: [UUID: CheckedContinuation<WaitResult, any Error>] = [:]

    var waiterCount: Int { waiters.count }

    func begin(_ generation: Int) {
        self.generation = generation
        outcome = nil
    }

    func finishPublished(_ generation: Int) {
        finish(generation, outcome: .published)
    }

    func finishFailed(_ generation: Int, error: any Error) {
        finish(generation, outcome: .failed(error))
    }

    func finishCancelled(_ generation: Int) {
        finish(
            generation,
            outcome: .replacementRequired(cancelledGeneration: generation)
        )
    }

    func invalidate(_ generation: Int) {
        self.generation = generation
        finish(generation, outcome: .invalidated)
    }

    /// Exactly one live waiter may claim a canceled generation. Other callers
    /// wait for publication even before the replacement loader begins.
    func claimReplacement(for cancelledGeneration: Int) -> Bool {
        guard generation == cancelledGeneration,
              case .replacementRequired(cancelledGeneration) = outcome
        else {
            return false
        }
        outcome = nil
        return true
    }

    func waitForCurrent() async throws -> WaitResult {
        try Task.checkCancellation()
        if let outcome {
            return try result(from: outcome)
        }
        let id = UUID()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<WaitResult, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
        try Task.checkCancellation()
        return result
    }

    private func finish(_ generation: Int, outcome: Outcome) {
        guard generation == self.generation else { return }
        self.outcome = outcome
        let pending = Array(waiters.values)
        waiters.removeAll()
        for waiter in pending {
            do {
                waiter.resume(returning: try result(from: outcome))
            } catch {
                waiter.resume(throwing: error)
            }
        }
    }

    private func result(from outcome: Outcome) throws -> WaitResult {
        switch outcome {
        case .published:
            return .published
        case .failed(let error):
            throw error
        case .replacementRequired(let cancelledGeneration):
            return .replacementRequired(cancelledGeneration: cancelledGeneration)
        case .invalidated:
            return .invalidated
        }
    }
}
