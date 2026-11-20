import Foundation

nonisolated struct RemoteTranscriptionStoreProduct: Sendable, Equatable, Identifiable {
    let id: String
    let displayName: String
    let displayPrice: String
    let grantSeconds: Int64
}
