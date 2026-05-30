public struct EmptyPodcastDiscoveryService: PodcastDiscoveryService {
    public init() {}

    public func popular(
        limit: Int,
        country: String,
        allowExplicit: Bool
    ) async throws -> [DirectoryPodcastResult] {
        []
    }
}
