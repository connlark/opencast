import Foundation

/// The worker rejects a counter not above the last one it verified, and `DCAppAttestService`
/// increments it at issuance, so two in-flight sends on one key can arrive reversed. One
/// process-wide gate keeps each key's issuance-to-response turns serial.
actor AppAttestAssertionGate {
    nonisolated static let shared = AppAttestAssertionGate()

    private let suspension: AppAttestSuspension

    init(suspension: AppAttestSuspension = .shared) {
        self.suspension = suspension
    }

    private var tails: [String: (id: UInt64, task: Task<Void, Never>)] = [:]
    private var nextTailID: UInt64 = 0

    var enqueuedSendCount: UInt64 { nextTailID }

    /// Distinct keys never wait on each other. Caller cancellation cancels this turn's operation
    /// but leaves the chain intact for the sends queued behind it.
    func withSerializedSend<T: Sendable>(
        keyID: String,
        exemptFromSuspension: Bool = false,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        if !exemptFromSuspension { try suspension.checkAdmission() }
        nextTailID += 1
        let tailID = nextTailID
        let previousTail = tails[keyID]?.task
        let work = Task {
            await previousTail?.value
            try Task.checkCancellation()
            if !exemptFromSuspension { try suspension.checkAdmission() }
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
