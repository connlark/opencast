import Foundation

nonisolated struct StreamingAudioCachedResponse: Equatable, Sendable {
    var data: Data
    var contentLength: Int64?
    var mimeType: String?
}
