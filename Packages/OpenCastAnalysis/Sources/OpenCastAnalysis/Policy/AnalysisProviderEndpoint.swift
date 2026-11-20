import Foundation

/// Paths may contain `{model}`, replaced with the entry's `modelID`.
public struct AnalysisProviderEndpoint: Sendable, Equatable, Decodable {
    public enum Auth: String, Sendable, Equatable, Decodable {
        case googleAPIKey = "x-goog-api-key"
        case bearer
    }

    public var baseURL: URL
    public var auth: Auth
    public var generatePath: String
    public var countTokensPath: String
    /// Constant headers such as an API version; never credentials.
    public var versionHeaders: [String: String]
    /// Raw text, not a `URL`, so the clamp checks it before any normalisation.
    public var keyPage: String?
    /// Overrides the transport's tier-check model when set.
    public var tierCheckModel: String?

    public var keyURL: URL? {
        keyPage.flatMap { URL(string: $0) }
    }

    enum CodingKeys: String, CodingKey {
        case baseURL = "base_url"
        case auth
        case generatePath = "generate_path"
        case countTokensPath = "count_tokens_path"
        case versionHeaders = "version_headers"
        case keyPage = "key_url"
        case tierCheckModel = "tier_check_model"
    }
}
