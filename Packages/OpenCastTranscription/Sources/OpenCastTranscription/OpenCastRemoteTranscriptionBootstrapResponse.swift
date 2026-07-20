/// Response of `account/bootstrap`: the opaque account plus its authoritative
/// balance. Purchase-backend lanes additionally return the per-account
/// StoreKit `appAccountToken`, the server catalog with its hash (the app
/// cross-checks against its embedded value and fails closed on mismatch),
/// and whether the store surfaces are currently enabled; the development
/// lane omits all of these.
public struct OpenCastRemoteTranscriptionBootstrapResponse: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var accountID: String
    public var balance: OpenCastRemoteTranscriptionBalance
    public var appAccountToken: String?
    public var catalog: [OpenCastRemoteTranscriptionCatalogProduct]?
    public var catalogSHA256: String?
    public var purchasesEnabled: Bool?

    public init(
        schemaVersion: Int,
        accountID: String,
        balance: OpenCastRemoteTranscriptionBalance,
        appAccountToken: String? = nil,
        catalog: [OpenCastRemoteTranscriptionCatalogProduct]? = nil,
        catalogSHA256: String? = nil,
        purchasesEnabled: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.accountID = accountID
        self.balance = balance
        self.appAccountToken = appAccountToken
        self.catalog = catalog
        self.catalogSHA256 = catalogSHA256
        self.purchasesEnabled = purchasesEnabled
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case accountID = "account_id"
        case balance
        case appAccountToken = "app_account_token"
        case catalog
        case catalogSHA256 = "catalog_sha256"
        case purchasesEnabled = "purchases_enabled"
    }
}
