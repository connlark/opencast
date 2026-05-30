import Foundation

nonisolated struct StreamingAudioCacheEntry: Sendable {
    var directory: URL
    var byteCount: Int64
    var manifest: StreamingAudioCacheManifest
}
