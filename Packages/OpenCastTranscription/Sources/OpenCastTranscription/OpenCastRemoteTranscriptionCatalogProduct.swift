/// Immutable per SKU; drift from the app's embedded catalog fails closed.
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
