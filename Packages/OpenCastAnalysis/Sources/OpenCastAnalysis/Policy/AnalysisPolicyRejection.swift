/// Why a policy bundle was not used. `code` is stable and content-free, for
/// run records and the diagnostics export.
public enum AnalysisPolicyRejection: Error, Sendable, Equatable, Codable {
    /// The download failed (offline, timeout, a non-200 status).
    case fetchFailed(String)
    /// The document or its signature was larger than the loader accepts.
    case tooLarge(bytes: Int)
    case signatureInvalid(String)
    case decodeFailed(String)
    case unsupportedSchemaVersion(Int)
    /// The bundle needs a newer app build than this one.
    case appBuildTooOld(required: Int, actual: Int)
    /// A value outside the app's hard bounds, or a malformed one. The whole
    /// bundle is rejected; `field` is the JSON path.
    case outOfBounds(field: String)
    /// The server offered a lower version than one already accepted.
    case rollback(accepted: Int, offered: Int)
    /// The cached bundle was not confirmed by the server for too long.
    case cacheStale(days: Int)
    /// An accepted bundle could not be written to disk; it stays active for
    /// this session and the refresh is retried.
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
