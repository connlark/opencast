import Foundation
import StoreKit

/// StoreKit 2 implementation of the purchase seam. Verified and unverified
/// transactions both surface their raw JWS — the server's Apple-library
/// verification is authoritative — except at purchase time, where a locally
/// unverified result is refused outright.
nonisolated struct LiveRemoteTranscriptionStoreKitClient: RemoteTranscriptionStoreKitClient {
    func environment() async throws -> RemoteTranscriptionStoreEnvironment {
        try await RemoteTranscriptionAppTransactionProvider.currentEnvironment()
    }

    func refreshEnvironment() async throws -> RemoteTranscriptionStoreEnvironment {
        try await RemoteTranscriptionAppTransactionProvider.refreshEnvironment()
    }

    func products(for identifiers: [String]) async throws -> [RemoteTranscriptionStoreProduct] {
        let products = try await Product.products(for: identifiers)
        let grants = RemoteTranscriptionEmbeddedCatalog.grantSecondsByProductID
        return products
            .sorted { $0.price < $1.price }
            .compactMap { product in
                guard let grantSeconds = grants[product.id] else { return nil }
                return RemoteTranscriptionStoreProduct(
                    id: product.id,
                    displayName: product.displayName,
                    displayPrice: product.displayPrice,
                    grantSeconds: grantSeconds
                )
            }
    }

    func purchase(
        productID: String,
        appAccountToken: UUID
    ) async throws -> RemoteTranscriptionStorePurchaseResult {
        guard let product = try await Product.products(for: [productID]).first else {
            throw RemoteTranscriptionHTTPError(
                statusCode: -1,
                code: "product_unavailable",
                detail: productID
            )
        }
        let result = try await product.purchase(options: [.appAccountToken(appAccountToken)])
        switch result {
        case .success(let verification):
            switch verification {
            case .verified(let transaction):
                return .success(
                    RemoteTranscriptionStoreTransaction(
                        id: transaction.id,
                        productID: transaction.productID,
                        jwsRepresentation: verification.jwsRepresentation,
                        purchaseDate: transaction.purchaseDate,
                        revocationDate: transaction.revocationDate
                    )
                )
            case .unverified:
                return .unverified
            }
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .unverified
        }
    }

    func unfinishedTransactions() async -> [RemoteTranscriptionStoreTransaction] {
        await collect(Transaction.unfinished)
    }

    func allTransactions() async -> [RemoteTranscriptionStoreTransaction] {
        await collect(Transaction.all)
    }

    func transactionUpdates() -> AsyncStream<RemoteTranscriptionStoreTransaction> {
        AsyncStream { continuation in
            let task = Task {
                for await update in Transaction.updates {
                    continuation.yield(Self.transaction(from: update))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func finish(transactionID: UInt64) async {
        for await update in Transaction.unfinished {
            switch update {
            case .verified(let transaction), .unverified(let transaction, _):
                if transaction.id == transactionID {
                    await transaction.finish()
                    return
                }
            }
        }
    }

    func syncPurchases() async throws {
        try await AppStore.sync()
    }

    private func collect(
        _ sequence: Transaction.Transactions
    ) async -> [RemoteTranscriptionStoreTransaction] {
        var transactions: [RemoteTranscriptionStoreTransaction] = []
        for await result in sequence {
            transactions.append(Self.transaction(from: result))
        }
        return transactions
    }

    private static func transaction(
        from result: VerificationResult<Transaction>
    ) -> RemoteTranscriptionStoreTransaction {
        switch result {
        case .verified(let transaction):
            RemoteTranscriptionStoreTransaction(
                id: transaction.id,
                productID: transaction.productID,
                jwsRepresentation: result.jwsRepresentation,
                purchaseDate: transaction.purchaseDate,
                revocationDate: transaction.revocationDate
            )
        case .unverified(let transaction, _):
            RemoteTranscriptionStoreTransaction(
                id: transaction.id,
                productID: transaction.productID,
                jwsRepresentation: result.jwsRepresentation,
                purchaseDate: transaction.purchaseDate,
                revocationDate: transaction.revocationDate,
                isVerified: false
            )
        }
    }
}
