/// `code` is kept in run records and exported: it stays stable and free of bundle content.
public enum AnalysisPolicyRejection: Error, Sendable, Equatable, Codable {
    case fetchFailed(String)
    case tooLarge(bytes: Int)
    case signatureInvalid(String)
    case decodeFailed(String)
    case unsupportedSchemaVersion(Int)
    case appBuildTooOld(required: Int, actual: Int)
    /// `field` is the JSON path.
    case outOfBounds(field: String)
    case rollback(accepted: Int, offered: Int)
    case cacheStale(days: Int)
    case persistenceFailed

    public var code: String {
        switch self {
        case .fetchFailed: "fetch_failed"
        case .tooLarge: "too_large"
        case .signatureInvalid: "signature_invalid"
        case .decodeFailed: "decode_failed"
        case .unsupportedSchemaVersion: "unsupported_schema_version"
        case .appBuildTooOld: "min_app_build"
        case let .outOfBounds(field): "out_of_bounds:\(field)"
        case .rollback: "rollback"
        case .cacheStale: "cache_stale"
        case .persistenceFailed: "persistence_failed"
        }
    }
}
