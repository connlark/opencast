import Foundation
import OpenCastCore
import Testing
@testable import OpenCast

@MainActor
@Suite("Podcast search store")
struct PodcastSearchStoreTests {
    @Test("Search query returns result rows", arguments: ["searchable", "24/7 news", "9:30/8:30 Central"])
    func searchQueryReturnsResultRows(query: String) async {
        let result = DirectoryPodcastResult(
            id: 1,
            title: "Searchable Show",
            artistName: "Searchable Host",
            feedURL: URL(string: "https://example.com/searchable.xml"),
            artworkURL: URL(string: "https://example.com/art.jpg")
        )
        let directoryService = StubPodcastDirectoryService(responses: [
            query: .success([result])
        ])
        let appModel = OpenCastAppModel(podcastDirectoryService: directoryService)
        let store = PodcastSearchStore(
            directoryService: appModel.podcastDirectoryService,
            knownPodcasts: appModel.knownPodcasts,
            debounceDuration: .zero
        )

        store.query = query
        await store.waitForCurrentSearch()

        #expect(store.state == .results([result]))
        #expect(await directoryService.requestedSearchQueries() == [query])
    }

    @Test("Empty query does not call the service")
    func emptyQueryDoesNotCallService() async {
        let directoryService = StubPodcastDirectoryService(responses: [:])
        let store = PodcastSearchStore(directoryService: directoryService, knownPodcasts: KnownPodcastsStore(), debounceDuration: .zero)

        store.query = "   "

        #expect(await directoryService.requestedSearchQueries().isEmpty)
        #expect(store.state == .idle)
    }

    @Test(
        "A feed address typed as the query is never sent to the directory",
        arguments: [
            "https://feeds.example.com/private.xml?token=secret",
            "https://user:secret@",
            "feeds.example.com/private.xml?token=secret",
            "https://feeds.example.com/My Show.xml?token=secret",
            "the feed is feeds.example.com/private.xml?token=secret",
            "feeds.example.com:8443/private.xml?token=secret",
            "192.0.2.10/private.xml?token=secret",
            "user:secret@feeds.example.com:8443/private.xml",
            "user:secret@feeds.example.com:8443",
            "//feeds.example.com:8443/private.xml?token=secret",
            "münchen.example.com:8443/private.xml?token=secret",
            "[2001:db8::1]:8443/private.xml?token=secret",
        ]
    )
    func feedAddressQueryIsNeverSentToTheDirectory(query: String) async {
        let directoryService = StubPodcastDirectoryService(responses: [:])
        let store = PodcastSearchStore(directoryService: directoryService, knownPodcasts: KnownPodcastsStore(), debounceDuration: .zero)

        store.query = query
        await store.waitForCurrentSearch()

        #expect(await directoryService.requestedSearchQueries().isEmpty)
        #expect(store.state == .idle)
    }

    @Test("Query changes cancel and replace previous result state")
    func queryChangesCancelAndReplacePreviousResultState() async {
        let oldResult = DirectoryPodcastResult(
            id: 1,
            title: "Old Show",
            feedURL: URL(string: "https://example.com/old.xml")
        )
        let newResult = DirectoryPodcastResult(
            id: 2,
            title: "New Show",
            feedURL: URL(string: "https://example.com/new.xml")
        )
        let directoryService = StubPodcastDirectoryService(responses: [
            "old": .delayedSuccess([oldResult], duration: .seconds(1)),
            "new": .success([newResult])
        ])
        let store = PodcastSearchStore(directoryService: directoryService, knownPodcasts: KnownPodcastsStore(), debounceDuration: .zero)

        store.query = "old"
        await directoryService.waitForRequestCount(1)

        store.query = "new"
        await store.waitForCurrentSearch()

        #expect(store.state == .results([newResult]))
        #expect(await directoryService.requestedSearchQueries() == ["old", "new"])
    }

    @Test("Service error surfaces in search state")
    func serviceErrorSurfacesInSearchState() async {
        let directoryService = StubPodcastDirectoryService(responses: [
            "broken": .failure("Directory unavailable")
        ])
        let store = PodcastSearchStore(directoryService: directoryService, knownPodcasts: KnownPodcastsStore(), debounceDuration: .zero)

        store.query = "broken"
        await store.waitForCurrentSearch()

        #expect(store.state == .error("Directory unavailable"))
    }
}

private actor StubPodcastDirectoryService: PodcastDirectoryService {
    enum Response: Sendable {
        case success([DirectoryPodcastResult])
        case failure(String)
        case delayedSuccess([DirectoryPodcastResult], duration: Duration)
    }

    private var responsesByQuery: [String: [Response]]
    private var requestedQueries: [String] = []
    private var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(responses: [String: Response]) {
        responsesByQuery = responses.mapValues { [$0] }
    }

    func search(query: String) async throws -> [DirectoryPodcastResult] {
        requestedQueries.append(query)
        resumeRequestWaiters()

        guard var responses = responsesByQuery[query],
              !responses.isEmpty
        else {
            throw StubDirectoryError(message: "No stub response for \(query)")
        }

        let response = responses.removeFirst()
        responsesByQuery[query] = responses

        switch response {
        case .success(let results):
            return results
        case .failure(let message):
            throw StubDirectoryError(message: message)
        case .delayedSuccess(let results, let duration):
            try await Task.sleep(for: duration)
            return results
        }
    }

    func requestedSearchQueries() -> [String] {
        requestedQueries
    }

    func waitForRequestCount(_ count: Int) async {
        if requestedQueries.count >= count {
            return
        }

        await withCheckedContinuation { continuation in
            requestWaiters.append((count, continuation))
        }
    }

    private func resumeRequestWaiters() {
        requestWaiters.removeAll { waiter in
            guard requestedQueries.count >= waiter.count else {
                return false
            }

            waiter.continuation.resume()
            return true
        }
    }
}

private struct StubDirectoryError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}
