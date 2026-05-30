import Foundation

nonisolated enum StreamingAudioCacheURL {
    static let scheme = "opencast-stream-cache"

    static func url(for originalURL: URL) -> URL {
        URL(string: "\(scheme)://audio/\(UUID().uuidString)") ?? originalURL
    }
}
