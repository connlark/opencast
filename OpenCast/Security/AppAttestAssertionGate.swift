import Foundation

/// Serializes App Attest assertion issuance → server response per key ID.
///
/// `DCAppAttestService` increments the assertion counter at issuance and the
/// worker rejects any envelope whose counter is not strictly higher than the
/// last one it verified. Five services send through independently
/// constructed secure clients, so without a process-wide gate two in-flight
/// sends can issue counters N and N+1 but arrive reversed — logged live as a
/// transient `invalid_counter` 401 in the 2026-07-31 dev traversal.
actor AppAttestAssertionGate {
    nonisolated static let shared = AppAttestAssertionGate()

    private var tails: [String: (id: UInt64, task: Task<Void, Never>)] = [:]
    private var nextTailID: UInt64 = 0

    /// Runs `operation` after every previously enqueued send for `keyID`
    /// has delivered its response (or failed). Distinct keys never wait on
    /// each other. Caller cancellation cancels this turn's operation but
    /// leaves the chain intact for the sends queued behind it.
    func withSerializedSend<T: Sendable>(
        keyID: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        nextTailID += 1
        let tailID = nextTailID
        let previousTail = tails[keyID]?.task
        let work = Task {
            await previousTail?.value
            try Task.checkCancellation()
            return try await operation()
        }
        tails[keyID] = (tailID, Task { _ = try? await work.value })
        defer {
            if tails[keyID]?.id == tailID {
                tails[keyID] = nil
            }
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}
