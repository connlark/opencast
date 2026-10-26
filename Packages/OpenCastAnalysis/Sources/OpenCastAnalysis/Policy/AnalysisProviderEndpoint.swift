import Foundation

/// Wire facts for one provider: where requests go and how the key is sent.
/// Paths may contain `{model}`, replaced with the entry's `modelID`.
public struct AnalysisProviderEndpoint: Sendable, Equatable, Decodable {
    public enum Auth: String, Sendable, Equatable, Decodable {
        /// `x-goog-api-key: <key>`
        case googleAPIKey = "x-goog-api-key"
        /// `Authorization: Bearer <key>`
        case bearer
    }

    public var baseURL: URL
    public var auth: Auth
    public var generatePath: String
    public var countTokensPath: String
    /// Extra constant headers the provider requires (an API version, for
    /// example). Never credentials.
    public var versionHeaders: [String: String]
    /// The page where a listener creates a key for this provider, as the
    /// bundle's raw text (the clamp checks this text, before any `URL`
    /// normalises it). `nil` in bundles that predate it.
    public var keyPage: String?

    /// `keyPage` to open in the browser from the key sheet.
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
    }
}
