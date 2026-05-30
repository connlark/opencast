import Foundation

public actor StreamingAudioCacheMaintenance {
    private let cache: StreamingAudioDiskCache

    public init(directory: URL) {
        cache = StreamingAudioDiskCache(directory: directory)
    }

    public func summary() async throws -> StreamingAudioCacheSummary {
        try await cache.summary()
    }

    public func clear() async throws {
        try await cache.clear()
    }

    public func prune(byteBudget: Int64) async throws {
        try await cache.prune(byteBudget: byteBudget)
    }

    public func remove(podcastID: String) async throws {
        try await cache.remove(podcastID: podcastID)
    }

    public func remove(episodeID: String) async throws {
        try await cache.remove(episodeID: episodeID)
    }
}
