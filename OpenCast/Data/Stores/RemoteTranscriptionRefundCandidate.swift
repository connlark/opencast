import Foundation

nonisolated struct RemoteTranscriptionRefundCandidate: Sendable, Equatable, Identifiable {
    let id: UInt64
    let productID: String
    let purchaseDate: Date
}
