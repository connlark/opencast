import Foundation
import StoreKit

nonisolated struct RemoteTranscriptionAppTransactionSnapshot: Sendable {
    let jwsRepresentation: String
    let environment: RemoteTranscriptionStoreEnvironment
}

/// AppTransaction is shared by the lane resolver and purchase bootstrap.
/// Coalescing it here guarantees both consumers make their decision from the
/// same signed snapshot, even when they start concurrently during launch.
actor RemoteTranscriptionAppTransactionCache {
    static let shared = RemoteTranscriptionAppTransactionCache()

    private typealias SnapshotStream = AsyncThrowingStream<
        RemoteTranscriptionAppTransactionSnapshot,
        Error
    >

    private let currentSnapshotLoader: @Sendable () async throws -> RemoteTranscriptionAppTransactionSnapshot
    private let refreshedSnapshotLoader: @Sendable () async throws -> RemoteTranscriptionAppTransactionSnapshot
    private var cachedSnapshot: RemoteTranscriptionAppTransactionSnapshot?
    private var lookup: (
        operationID: UUID,
        isRefresh: Bool,
        task: Task<Void, Never>,
        waiters: [UUID: SnapshotStream.Continuation]
    )?

    init(
        currentSnapshotLoader: @escaping @Sendable () async throws -> RemoteTranscriptionAppTransactionSnapshot =
            RemoteTranscriptionAppTransactionCache.loadCurrentSnapshot,
        refreshedSnapshotLoader: @escaping @Sendable () async throws -> RemoteTranscriptionAppTransactionSnapshot =
            RemoteTranscriptionAppTransactionCache.loadRefreshedSnapshot
    ) {
        self.currentSnapshotLoader = currentSnapshotLoader
        self.refreshedSnapshotLoader = refreshedSnapshotLoader
    }

    func snapshot() async throws -> RemoteTranscriptionAppTransactionSnapshot {
        if let cachedSnapshot {
            try Task.checkCancellation()
            return cachedSnapshot
        }

        return try await value(refreshing: false)
    }

    func refreshedSnapshot() async throws -> RemoteTranscriptionAppTransactionSnapshot {
        try await value(refreshing: true)
    }

    private func value(
        refreshing: Bool
    ) async throws -> RemoteTranscriptionAppTransactionSnapshot {
        try Task.checkCancellation()
        prepareLookup(refreshing: refreshing)

        let waiterID = UUID()
        let (stream, continuation) = SnapshotStream.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        continuation.onTermination = { _ in
            Task { await self.cancelWaiter(id: waiterID) }
        }
        guard var lookup else {
            continuation.finish(throwing: CancellationError())
            throw CancellationError()
        }
        lookup.waiters[waiterID] = continuation
        self.lookup = lookup

        do {
            return try await withTaskCancellationHandler {
                for try await snapshot in stream {
                    try Task.checkCancellation()
                    return snapshot
                }
                throw CancellationError()
            } onCancel: {
                Task { await self.cancelWaiter(id: waiterID) }
            }
        } catch {
            cancelWaiter(id: waiterID)
            throw error
        }
    }

    private func prepareLookup(refreshing: Bool) {
        if refreshing {
            cachedSnapshot = nil
            guard lookup?.isRefresh != true else { return }

            let existingWaiters = lookup?.waiters ?? [:]
            lookup?.task.cancel()
            startLookup(refreshing: true, waiters: existingWaiters)
        } else if lookup == nil {
            startLookup(refreshing: false, waiters: [:])
        }
    }

    private func startLookup(
        refreshing: Bool,
        waiters: [UUID: SnapshotStream.Continuation]
    ) {
        let operationID = UUID()
        let loader = refreshing ? refreshedSnapshotLoader : currentSnapshotLoader
        let task = Task {
            let result: Result<RemoteTranscriptionAppTransactionSnapshot, Error>
            do {
                result = .success(try await loader())
            } catch {
                result = .failure(error)
            }
            completeLookup(operationID: operationID, result: result)
        }
        lookup = (operationID, refreshing, task, waiters)
    }

    private func completeLookup(
        operationID: UUID,
        result: Result<RemoteTranscriptionAppTransactionSnapshot, Error>
    ) {
        guard let lookup, lookup.operationID == operationID else { return }
        self.lookup = nil

        switch result {
        case .success(let snapshot):
            cachedSnapshot = snapshot
            for continuation in lookup.waiters.values {
                continuation.yield(snapshot)
                continuation.finish()
            }
        case .failure(let error):
            for continuation in lookup.waiters.values {
                continuation.finish(throwing: error)
            }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard var lookup,
              let continuation = lookup.waiters.removeValue(forKey: id)
        else { return }

        if lookup.waiters.isEmpty {
            self.lookup = nil
            lookup.task.cancel()
        } else {
            self.lookup = lookup
        }
        continuation.finish(throwing: CancellationError())
    }

    nonisolated private static func loadCurrentSnapshot() async throws -> RemoteTranscriptionAppTransactionSnapshot {
        snapshot(from: try await AppTransaction.shared)
    }

    nonisolated private static func loadRefreshedSnapshot() async throws -> RemoteTranscriptionAppTransactionSnapshot {
        snapshot(from: try await AppTransaction.refresh())
    }

    nonisolated private static func snapshot(
        from result: VerificationResult<AppTransaction>
    ) -> RemoteTranscriptionAppTransactionSnapshot {
        switch result {
        case .verified(let transaction), .unverified(let transaction, _):
            RemoteTranscriptionAppTransactionSnapshot(
                jwsRepresentation: result.jwsRepresentation,
                environment: RemoteTranscriptionStoreEnvironment(transaction.environment)
            )
        }
    }
}

/// Fetches the device's AppTransaction for lanes that key identity to it.
/// The raw JWS goes to the server, which performs the authoritative
/// verification with Apple's library — the app never trusts its own parse.
nonisolated enum RemoteTranscriptionAppTransactionProvider {
    static func currentJWS() async throws -> String? {
        try await RemoteTranscriptionAppTransactionCache.shared.snapshot().jwsRepresentation
    }

    static func currentEnvironment() async throws -> RemoteTranscriptionStoreEnvironment {
        try await RemoteTranscriptionAppTransactionCache.shared.snapshot().environment
    }

    static func refreshEnvironment() async throws -> RemoteTranscriptionStoreEnvironment {
        try await RemoteTranscriptionAppTransactionCache.shared.refreshedSnapshot().environment
    }
}
