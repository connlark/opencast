import Foundation

nonisolated struct StreamingAudioLoadingResponse: Sendable {
    var data: Data
    var contentLength: Int64?
    var mimeType: String?
}
