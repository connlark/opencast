import Foundation

nonisolated struct StreamingAudioRangeMetadata: Equatable, Sendable {
    var contentLength: Int64?
    var mimeType: String?
    var etag: String?
    var lastModified: String?
    var acceptsRanges: Bool
    var responseURL: URL?

    var hasValidator: Bool {
        etag?.isEmpty == false || lastModified?.isEmpty == false
    }
}
