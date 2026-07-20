/// One server-catalog entry: a consumable product and the exact seconds it
/// grants. The mapping is immutable per SKU; drift between this and the
/// app's embedded catalog is a fail-closed condition.
public struct OpenCastRemoteTranscriptionCatalogProduct: Codable, Sendable, Equatable, Hashable {
    public var productID: String
    public var grantSeconds: Int64

    public init(productID: String, grantSeconds: Int64) {
        self.productID = productID
        self.grantSeconds = grantSeconds
    }

    enum CodingKeys: String, CodingKey {
        case productID = "product_id"
        case grantSeconds = "grant_seconds"
    }
}
