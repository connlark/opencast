import Foundation

nonisolated protocol RemoteTranscriptionStoreKitClient: Sendable {
    func environment() async throws -> RemoteTranscriptionStoreEnvironment
    /// May display App Store sign-in, so only an explicit user action calls this.
    func refreshEnvironment() async throws -> RemoteTranscriptionStoreEnvironment
    func products(for identifiers: [String]) async throws -> [RemoteTranscriptionStoreProduct]
    func purchase(
        productID: String,
        appAccountToken: UUID
    ) async throws -> RemoteTranscriptionStorePurchaseResult
    func unfinishedTransactions() async -> [RemoteTranscriptionStoreTransaction]
    /// Includes consumables only when `SKIncludeConsumableInAppPurchaseHistory` is set.
    func allTransactions() async -> [RemoteTranscriptionStoreTransaction]
    func transactionUpdates() -> AsyncStream<RemoteTranscriptionStoreTransaction>
    func finish(transactionID: UInt64) async
    /// `AppStore.sync()` — only ever called from an explicit user gesture.
    func syncPurchases() async throws
}
