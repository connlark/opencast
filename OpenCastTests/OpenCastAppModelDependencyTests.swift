import Foundation
import OpenCastCore
import Testing
@testable import OpenCast

@MainActor
@Suite("OpenCast app model dependency wiring")
struct OpenCastAppModelDependencyTests {
    @Test("Custom directory without discovery uses empty popular discovery")
    func customDirectoryWithoutDiscoveryUsesEmptyPopularDiscovery() async throws {
        let appModel = OpenCastAppModel(podcastDirectoryService: StubAppModelDirectoryService())

        let popularResults = try await appModel.podcastDiscoveryService.popular(
            limit: 5,
            country: "us",
            allowExplicit: true
        )

        #expect(popularResults.isEmpty)
    }

    @Test("Explicit discovery service is preserved")
    func explicitDiscoveryServiceIsPreserved() async throws {
        let expectedResult = DirectoryPodcastResult(
            id: 42,
            title: "Injected Popular Show",
            feedURL: URL(string: "https://example.com/injected.xml")
        )
        let appModel = OpenCastAppModel(
            podcastDirectoryService: StubAppModelDirectoryService(),
            podcastDiscoveryService: StubAppModelDiscoveryService(results: [expectedResult])
        )

        let popularResults = try await appModel.podcastDiscoveryService.popular(
            limit: 5,
            country: "us",
            allowExplicit: true
        )

        #expect(popularResults == [expectedResult])
    }
}

private struct StubAppModelDirectoryService: PodcastDirectoryService {
    func search(query: String) async throws -> [DirectoryPodcastResult] {
        []
    }
}

private struct StubAppModelDiscoveryService: PodcastDiscoveryService {
    let results: [DirectoryPodcastResult]

    func popular(
        limit: Int,
        country: String,
        allowExplicit: Bool
    ) async throws -> [DirectoryPodcastResult] {
        results
    }
}
