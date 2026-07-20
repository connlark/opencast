import Foundation

/// Outcome of a purchase attempt through the StoreKit seam.
nonisolated enum RemoteTranscriptionStorePurchaseResult: Sendable, Equatable {
    case success(RemoteTranscriptionStoreTransaction)
    /// Deferred (e.g. Ask to Buy): the transaction arrives later through
    /// `transactionUpdates()` if approved.
    case pending
    case cancelled
    /// StoreKit could not verify the transaction locally; nothing is sent to
    /// the server and nothing is finished.
    case unverified
}
