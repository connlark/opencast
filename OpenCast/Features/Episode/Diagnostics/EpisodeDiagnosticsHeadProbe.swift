import Foundation

/// Outcome of one HEAD probe: the redirect chain followed, the final
/// response's identity headers, and any transport error. Never carries a
/// response body — probes must not accidentally download media.
nonisolated struct EpisodeDiagnosticsHeadProbe: Sendable, Equatable {
    var requestedURL: String
    var redirectURLs: [String] = []
    var finalURL: String?
    var statusCode: Int?
    var mimeType: String?
    var contentLength: Int64?
    var acceptRanges: String?
    var entityTag: String?
    var lastModified: String?
    var errorDescription: String?
}
