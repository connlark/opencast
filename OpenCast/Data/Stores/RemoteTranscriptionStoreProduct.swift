import Foundation

/// StoreKit-free product surface for the transcription store UI: identity,
/// localized presentation, and the server-granted seconds resolved from the
/// verified catalog.
nonisolated struct RemoteTranscriptionStoreProduct: Sendable, Equatable, Identifiable {
    let id: String
    let displayName: String
    let displayPrice: String
    let grantSeconds: Int64
}
