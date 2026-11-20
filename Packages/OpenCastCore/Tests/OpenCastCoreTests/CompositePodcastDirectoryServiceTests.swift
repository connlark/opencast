import Foundation
import OpenCastCore
import Synchronization
import Testing

@Suite("Composite podcast directory service")
struct CompositePodcastDirectoryServiceTests {
    private let appleResult = DirectoryPodcastResult(
        id: 1,
        title: "Apple Show",
        feedURL: URL(string: "https://example.com/apple.xml")
    )
    private let podcastIndexResult = DirectoryPodcastResult(
        id: "podcastindex:11",
        title: "PI Show",
        feedURL: URL(string: "https://example.com/pi.xml"),
        podcastIndexID: 11,
        sources: [.podcastIndex],
        feedCandidates: [
            DirectoryFeedCandidate(source: .podcastIndex, feedURL: URL(string: "https://example.com/pi.xml")!)
        ]
    )

    @Test("Merges both providers when both succeed")
    func mergesBothProviders() async throws {
        let service = CompositePodcastDirectoryService(
            apple: StubDirectoryProvider(searchResult: .success([appleResult])),
            podcastIndex: StubDirectoryProvider(searchResult: .success([podcastIndexResult]))
        )

        let results = try await service.search(query: "shows")

        #expect(results.map(\.title) == ["Apple Show", "PI Show"])
    }

    @Test("Falls back to Apple when Podcast Index fails")
    func fallsBackToApple() async throws {
        let service = CompositePodcastDirectoryService(
            apple: StubDirectoryProvider(searchResult: .success([appleResult])),
            podcastIndex: StubDirectoryProvider(searchResult: .failure(StubProviderError(message: "pi down")))
        )

        let results = try await service.search(query: "shows")

        #expect(results.map(\.title) == ["Apple Show"])
    }

    @Test("Falls back to Podcast Index when Apple fails")
    func fallsBackToPodcastIndex() async throws {
        let service = CompositePodcastDirectoryService(
            apple: StubDirectoryProvider(searchResult: .failure(StubProviderError(message: "apple down"))),
            podcastIndex: StubDirectoryProvider(searchResult: .success([podcastIndexResult]))
        )

        let results = try await service.search(query: "shows")

        #expect(results.map(\.title) == ["PI Show"])
    }

    @Test("Surfaces the Apple error when both providers fail")
    func surfacesAppleErrorWhenBothFail() async {
        let service = CompositePodcastDirectoryService(
            apple: StubDirectoryProvider(searchResult: .failure(StubProviderError(message: "apple down"))),
            podcastIndex: StubDirectoryProvider(searchResult: .failure(StubProviderError(message: "pi down")))
        )

        await #expect(throws: StubProviderError(message: "apple down")) {
            try await service.search(query: "shows")
        }
    }

    @Test("A hung provider is bounded by the provider timeout")
    func hungProviderIsBounded() async throws {
        let service = CompositePodcastDirectoryService(
            apple: StubDirectoryProvider(searchResult: .success([appleResult])),
            podcastIndex: StubDirectoryProvider(
                searchResult: .success([podcastIndexResult]),
                delay: .seconds(30)
            ),
            providerTimeout: .milliseconds(50)
        )

        let results = try await service.search(query: "shows")

        #expect(results.map(\.title) == ["Apple Show"])
    }

    @Test("Cancellation propagates into providers")
    func cancellationPropagates() async {
        let cancelled = Mutex(0)
        let service = CompositePodcastDirectoryService(
            apple: StubDirectoryProvider(
                searchResult: .success([appleResult]),
                delay: .seconds(30),
                onCancel: { cancelled.withLock { $0 += 1 } }
            ),
            podcastIndex: StubDirectoryProvider(
                searchResult: .success([podcastIndexResult]),
                delay: .seconds(30),
                onCancel: { cancelled.withLock { $0 += 1 } }
            ),
            providerTimeout: .seconds(60)
        )

        let task = Task {
            try await service.search(query: "shows")
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(cancelled.withLock { $0 } == 2)
    }

    @Test("Lookup goes to the Podcast Index provider")
    func lookupUsesPodcastIndexProvider() async throws {
        let service = CompositePodcastDirectoryService(
            apple: StubDirectoryProvider(searchResult: .success([])),
            podcastIndex: StubDirectoryProvider(
                searchResult: .success([]),
                lookupResult: .success(podcastIndexResult)
            )
        )

        let result = try await service.lookup(appleID: 917_918_570)

        #expect(result?.podcastIndexID == 11)
    }
}

private struct StubDirectoryProvider: PodcastDirectoryService {
    var searchResult: Result<[DirectoryPodcastResult], StubProviderError>
    var lookupResult: Result<DirectoryPodcastResult?, StubProviderError> = .success(nil)
    var delay: Duration = .zero
    var onCancel: @Sendable () -> Void = {}

    func search(query: String) async throws -> [DirectoryPodcastResult] {
        if delay > .zero {
            do {
                try await Task.sleep(for: delay)
            } catch {
                onCancel()
                throw error
            }
        }
        return try searchResult.get()
    }

    func lookup(appleID: Int) async throws -> DirectoryPodcastResult? {
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return try lookupResult.get()
    }
}

private struct StubProviderError: Error, Equatable {
    let message: String
}
