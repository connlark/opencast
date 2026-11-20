import Foundation
import OpenCastCore
import Testing
@testable import OpenCast

@MainActor
@Suite("Podcast search store")
struct PodcastSearchStoreTests {
    @Test("Search query returns result rows")
    func searchQueryReturnsResultRows() async {
        let result = DirectoryPodcastResult(
            id: 1,
            title: "Searchable Show",
            artistName: "Searchable Host",
            feedURL: URL(string: "https://example.com/searchable.xml"),
            artworkURL: URL(string: "https://example.com/art.jpg")
        )
        let directoryService = StubPodcastDirectoryService(responses: [
            "searchable": .success([result])
        ])
        let appModel = OpenCastAppModel(podcastDirectoryService: directoryService)
        let store = PodcastSearchStore(
            directoryService: appModel.podcastDirectoryService,
            debounceDuration: .zero
        )

        store.query = "searchable"
        await store.waitForCurrentSearch()

        #expect(store.state == .results([result]))
        #expect(await directoryService.requestedSearchQueries() == ["searchable"])
    }

    @Test("Empty query does not call the service")
    func emptyQueryDoesNotCallService() async {
        let directoryService = StubPodcastDirectoryService(responses: [:])
        let store = PodcastSearchStore(directoryService: directoryService, debounceDuration: .zero)

        store.query = "   "

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
        let store = PodcastSearchStore(directoryService: directoryService, debounceDuration: .zero)

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
        let store = PodcastSearchStore(directoryService: directoryService, debounceDuration: .zero)

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
