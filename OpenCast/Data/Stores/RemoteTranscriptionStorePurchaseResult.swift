import Foundation

nonisolated enum RemoteTranscriptionStorePurchaseResult: Sendable, Equatable {
    case success(RemoteTranscriptionStoreTransaction)
    case pending
    case cancelled
    case unverified
}
