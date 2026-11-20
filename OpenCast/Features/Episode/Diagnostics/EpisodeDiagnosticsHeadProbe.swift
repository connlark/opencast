import Foundation

/// Never carries a response body: a probe must not download media.
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
