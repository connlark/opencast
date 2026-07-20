import Foundation

/// StoreKit 2 seam for the purchase store. Injected so the outcome matrix
/// (pending/cancelled/unverified/verified, finish-only-after-ack, launch
/// reconciliation) runs against fakes in simulator tests.
nonisolated protocol RemoteTranscriptionStoreKitClient: Sendable {
    func environment() async throws -> RemoteTranscriptionStoreEnvironment
    /// Explicit-user-action fallback when the cached AppTransaction is
    /// unavailable. The live implementation may display App Store sign-in.
    func refreshEnvironment() async throws -> RemoteTranscriptionStoreEnvironment
    func products(for identifiers: [String]) async throws -> [RemoteTranscriptionStoreProduct]
    func purchase(
        productID: String,
        appAccountToken: UUID
    ) async throws -> RemoteTranscriptionStorePurchaseResult
    /// Transactions StoreKit still considers unfinished (credit may be owed).
    func unfinishedTransactions() async -> [RemoteTranscriptionStoreTransaction]
    /// Full history batch (requires `SKIncludeConsumableInAppPurchaseHistory`
    /// for consumables); the reconciliation sweep behind "Refresh Purchases".
    func allTransactions() async -> [RemoteTranscriptionStoreTransaction]
    func transactionUpdates() -> AsyncStream<RemoteTranscriptionStoreTransaction>
    func finish(transactionID: UInt64) async
    /// `AppStore.sync()` — only ever called from an explicit user gesture.
    func syncPurchases() async throws
}
