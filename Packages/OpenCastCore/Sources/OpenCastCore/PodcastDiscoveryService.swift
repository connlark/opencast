import Foundation

public protocol PodcastDiscoveryService: Sendable {
    func popular(
        limit: Int,
        country: String,
        allowExplicit: Bool
    ) async throws -> [DirectoryPodcastResult]
}
