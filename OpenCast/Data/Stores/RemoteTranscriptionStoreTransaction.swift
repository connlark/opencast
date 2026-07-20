import Foundation

/// StoreKit-free transaction handle: enough to redeem (signed JWS goes to
/// the server) and to finish by id after the server acknowledges.
nonisolated struct RemoteTranscriptionStoreTransaction: Sendable, Equatable {
    let id: UInt64
    let productID: String
    let jwsRepresentation: String
    let purchaseDate: Date?
    let revocationDate: Date?
    let isVerified: Bool

    init(
        id: UInt64,
        productID: String,
        jwsRepresentation: String,
        purchaseDate: Date? = nil,
        revocationDate: Date? = nil,
        isVerified: Bool = true
    ) {
        self.id = id
        self.productID = productID
        self.jwsRepresentation = jwsRepresentation
        self.purchaseDate = purchaseDate
        self.revocationDate = revocationDate
        self.isVerified = isVerified
    }
}
