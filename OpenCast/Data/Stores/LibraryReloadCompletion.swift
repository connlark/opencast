import Foundation

/// Superseding a reload may discard its snapshot, but its caller must still
/// wait for a published library before restoring playback or pruning history.
final class LibraryReloadCompletion {
    private var generation = 0
    private var outcome: Result<Void, any Error>? = .success(())
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    func begin(_ generation: Int) {
        self.generation = generation
        outcome = nil
    }

    func finish(_ generation: Int, outcome: Result<Void, any Error>) {
        guard generation == self.generation else { return }
        self.outcome = outcome
        let pending = Array(waiters.values)
        waiters.removeAll()
        for waiter in pending { waiter.resume(with: outcome) }
    }

    func invalidate(_ generation: Int) {
        begin(generation)
        finish(generation, outcome: .failure(CancellationError()))
    }

    func waitForCurrent() async throws {
        try Task.checkCancellation()
        if let outcome { return try outcome.get() }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor in
                self.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
        try Task.checkCancellation()
    }
}
