import Foundation

/// Shared across every DefaultFeedService instance. A queued task owns no
/// transport and cancellation removes it without consuming an admission slot.
actor FeedPreparationGate {
    static let shared = FeedPreparationGate()
    private static let maximumInteractiveBurst = 3

    private struct Waiter {
        let id: UUID
        let intent: FeedPreparationIntent
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var active = 0
    private var waiters: [Waiter] = []
    private var consecutiveInteractiveAdmissions = 0
    private let handoffCheckpoint: (@Sendable () async -> Void)?

    init(handoffCheckpoint: (@Sendable () async -> Void)? = nil) {
        self.handoffCheckpoint = handoffCheckpoint
    }

    func acquire(intent: FeedPreparationIntent = .interactive) async throws {
        try Task.checkCancellation()
        if active < 2 {
            active += 1
            recordAdmission(intent)
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append(Waiter(id: id, intent: intent, continuation: continuation)) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        await handoffCheckpoint?()
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    func release() {
        guard let index = nextWaiterIndex() else {
            active -= 1
            return
        }
        let waiter = waiters.remove(at: index)
        recordAdmission(waiter.intent)
        waiter.continuation.resume()
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func nextWaiterIndex() -> Int? {
        guard !waiters.isEmpty else {
            return nil
        }
        let automaticIndex = waiters.firstIndex { $0.intent == .automatic }
        let interactiveIndex = waiters.firstIndex { $0.intent == .interactive }
        if consecutiveInteractiveAdmissions >= Self.maximumInteractiveBurst,
           let automaticIndex {
            return automaticIndex
        }
        return interactiveIndex ?? automaticIndex
    }

    private func recordAdmission(_ intent: FeedPreparationIntent) {
        switch intent {
        case .interactive:
            consecutiveInteractiveAdmissions += 1
        case .automatic:
            consecutiveInteractiveAdmissions = 0
        }
    }

    func queuedCounts() -> (interactive: Int, automatic: Int) {
        (
            waiters.count { $0.intent == .interactive },
            waiters.count { $0.intent == .automatic }
        )
    }
}
