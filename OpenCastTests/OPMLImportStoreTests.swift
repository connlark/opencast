import Foundation
import OpenCastCore
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import OpenCast

@MainActor
@Suite("OPML import and export")
struct OPMLImportStoreTests {
    @Test("OPML picker accepts only OPML and XML")
    func opmlPickerAcceptsOnlyOPMLAndXML() {
        #expect(OPMLFileDocument.readableContentTypes == [.opml, .xml])
        #expect(!OPMLFileDocument.readableContentTypes.contains(.data))
    }

    @Test("Imports valid feeds and creates subscription and cache rows")
    func importsValidFeeds() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let firstFeed = "https://example.com/one.xml"
        let secondFeed = "https://example.com/two.xml"
        let feedService = StubOPMLFeedService(responses: [
            firstFeed: .success(makeSnapshot(feedURL: firstFeed, podcastTitle: "One Show")),
            secondFeed: .success(makeSnapshot(feedURL: secondFeed, podcastTitle: "Two Show"))
        ])
        let libraryStore = LibraryStore(feedService: feedService)
        let importStore = OPMLImportStore()

        await importStore.importOPML(
            data: opmlData([
                ("One Show", firstFeed),
                ("Two Show", secondFeed)
            ]),
            libraryStore: libraryStore,
            modelContext: context
        )

        let result = try importedResult(from: importStore.state)
        let subscriptions = try context.fetch(FetchDescriptor<SubscriptionRecord>())
            .sorted { $0.feedURL < $1.feedURL }
        let podcastCaches = try context.fetch(FetchDescriptor<PodcastCacheRecord>())
            .sorted { $0.feedURL < $1.feedURL }
        let episodeCaches = try context.fetch(FetchDescriptor<EpisodeCacheRecord>())
            .sorted { $0.podcastID < $1.podcastID }

        #expect(result.totalFeedReferencesFound == 2)
        #expect(result.importedCount == 2)
        #expect(result.skippedDuplicateCount == 0)
        #expect(result.failedCount == 0)
        #expect(await feedService.requestedURLStrings() == [firstFeed, secondFeed])
        #expect(subscriptions.map(\.feedURL) == [firstFeed, secondFeed])
        #expect(podcastCaches.map(\.feedURL) == [firstFeed, secondFeed])
        #expect(episodeCaches.map(\.podcastID) == [firstFeed, secondFeed])
        #expect(libraryStore.subscriptions.map(\.feedURL) == [firstFeed, secondFeed])
    }

    @Test("Imports valid feeds from a file URL")
    func importsValidFeedsFromFileURL() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedURL = "https://example.com/file-import.xml"
        let feedService = StubOPMLFeedService(responses: [
            feedURL: .success(makeSnapshot(feedURL: feedURL, podcastTitle: "File Import Show"))
        ])
        let libraryStore = LibraryStore(feedService: feedService)
        let importStore = OPMLImportStore()
        let fileURL = try temporaryFile(named: "subscriptions.opml", data: opmlData([
            ("File Import Show", feedURL)
        ]))
        defer {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }

        await importStore.importOPML(
            from: fileURL,
            libraryStore: libraryStore,
            modelContext: context
        )

        let result = try importedResult(from: importStore.state)
        let subscriptions = try context.fetch(FetchDescriptor<SubscriptionRecord>())

        #expect(result.totalFeedReferencesFound == 1)
        #expect(result.importedCount == 1)
        #expect(result.failedCount == 0)
        #expect(await feedService.requestedURLStrings() == [feedURL])
        #expect(subscriptions.map(\.feedURL) == [feedURL])
    }

    @Test("Rejects oversized OPML files before importing")
    func rejectsOversizedOPMLFiles() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedService = StubOPMLFeedService(responses: [:])
        let libraryStore = LibraryStore(feedService: feedService)
        let importStore = OPMLImportStore()
        let oversizedData = Data(repeating: 0, count: 11 * 1_024 * 1_024)
        let fileURL = try temporaryFile(named: "oversized.opml", data: oversizedData)
        defer {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }

        await importStore.importOPML(
            from: fileURL,
            libraryStore: libraryStore,
            modelContext: context
        )

        #expect(importStore.state == .failed("OPML files larger than 10 MB are not supported."))
        #expect(await feedService.requestedURLStrings().isEmpty)
    }

    @Test("Imports HTTP podcast feeds from OPML")
    func importsHTTPPodcastFeedsFromOPML() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedURL = "http://example.com/subscriber-feed.xml"
        let feedService = StubOPMLFeedService(responses: [
            feedURL: .success(makeSnapshot(feedURL: feedURL, podcastTitle: "Example Subscriber Podcast"))
        ])
        let libraryStore = LibraryStore(feedService: feedService)
        let importStore = OPMLImportStore()

        await importStore.importOPML(
            data: opmlData([
                ("Example Subscriber Podcast \u{2014} Subscriber Feed", feedURL)
            ]),
            libraryStore: libraryStore,
            modelContext: context
        )

        let result = try importedResult(from: importStore.state)
        let subscriptions = try context.fetch(FetchDescriptor<SubscriptionRecord>())

        #expect(result.totalFeedReferencesFound == 1)
        #expect(result.importedCount == 1)
        #expect(result.failedCount == 0)
        #expect(await feedService.requestedURLStrings() == [feedURL])
        #expect(subscriptions.map(\.feedURL) == [feedURL])
    }

    @Test("Skips already subscribed feed")
    func skipsAlreadySubscribedFeed() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let existingFeed = "https://example.com/existing.xml"
        let newFeed = "https://example.com/new.xml"
        let feedService = StubOPMLFeedService(responses: [
            newFeed: .success(makeSnapshot(feedURL: newFeed, podcastTitle: "New Show"))
        ])
        let libraryStore = LibraryStore(feedService: feedService)
        let importStore = OPMLImportStore()

        context.insert(SubscriptionRecord(feedURL: existingFeed, title: "Existing Show"))
        try context.save()

        await importStore.importOPML(
            data: opmlData([
                ("Existing Show", existingFeed),
                ("New Show", newFeed)
            ]),
            libraryStore: libraryStore,
            modelContext: context
        )

        let result = try importedResult(from: importStore.state)
        let subscriptions = try context.fetch(FetchDescriptor<SubscriptionRecord>())

        #expect(result.totalFeedReferencesFound == 2)
        #expect(result.importedCount == 1)
        #expect(result.skippedDuplicateCount == 1)
        #expect(result.failedCount == 0)
        #expect(await feedService.requestedURLStrings() == [newFeed])
        #expect(Set(subscriptions.map(\.feedURL)) == [existingFeed, newFeed])
    }

    @Test("Duplicate OPML entries import once")
    func duplicateEntriesImportOnce() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedURL = "https://example.com/duplicate.xml"
        let feedService = StubOPMLFeedService(responses: [
            feedURL: .success(makeSnapshot(feedURL: feedURL, podcastTitle: "Duplicate Show"))
        ])
        let libraryStore = LibraryStore(feedService: feedService)
        let importStore = OPMLImportStore()

        await importStore.importOPML(
            data: opmlData([
                ("Duplicate Show", feedURL),
                ("Duplicate Show Again", feedURL)
            ]),
            libraryStore: libraryStore,
            modelContext: context
        )

        let result = try importedResult(from: importStore.state)
        let subscriptions = try context.fetch(FetchDescriptor<SubscriptionRecord>())

        #expect(result.totalFeedReferencesFound == 2)
        #expect(result.importedCount == 1)
        #expect(result.skippedDuplicateCount == 1)
        #expect(result.failedCount == 0)
        #expect(await feedService.requestedURLStrings() == [feedURL])
        #expect(subscriptions.map(\.feedURL) == [feedURL])
    }

    @Test("Bad feed does not abort import")
    func badFeedDoesNotAbortImport() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let goodFeed = "https://example.com/good.xml"
        let badFeed = "https://example.com/bad.xml"
        let feedService = StubOPMLFeedService(responses: [
            goodFeed: .success(makeSnapshot(feedURL: goodFeed, podcastTitle: "Good Show")),
            badFeed: .failure("Feed is not parseable")
        ])
        let libraryStore = LibraryStore(feedService: feedService)
        let importStore = OPMLImportStore()

        await importStore.importOPML(
            data: opmlData([
                ("Good Show", goodFeed),
                ("Bad Show", badFeed)
            ]),
            libraryStore: libraryStore,
            modelContext: context
        )

        let result = try importedResult(from: importStore.state)
        let subscriptions = try context.fetch(FetchDescriptor<SubscriptionRecord>())

        #expect(result.totalFeedReferencesFound == 2)
        #expect(result.importedCount == 1)
        #expect(result.skippedDuplicateCount == 0)
        #expect(result.failedCount == 1)
        #expect(result.failures.first?.feedURL == badFeed)
        #expect(result.failures.first?.message == "Feed is not parseable")
        #expect(await feedService.requestedURLStrings() == [goodFeed, badFeed])
        #expect(subscriptions.map(\.feedURL) == [goodFeed])
    }

    @Test("Exports active subscriptions and round-trips through parser")
    func exportsActiveSubscriptionsRoundTrip() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let libraryStore = LibraryStore()

        context.insert(SubscriptionRecord(feedURL: "https://example.com/b.xml", title: "B Show"))
        context.insert(SubscriptionRecord(feedURL: "https://example.com/a.xml", title: "A Show"))
        context.insert(
            SubscriptionRecord(
                feedURL: "https://example.com/archived.xml",
                title: "Archived Show",
                isArchived: true
            )
        )
        try context.save()
        libraryStore.load(modelContext: context)

        let data = try OPMLExportBuilder.data(
            from: libraryStore.subscriptions,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let references = try OPMLParser().parse(data: data)

        #expect(references.map(\.title) == ["A Show", "B Show"])
        #expect(references.map(\.canonicalFeedURL) == [
            "https://example.com/a.xml",
            "https://example.com/b.xml"
        ])
    }

    private func makeSnapshot(feedURL: String, podcastTitle: String) -> FeedSnapshot {
        let canonicalFeedURL = URLCanonicalizer.canonicalString(forRawString: feedURL)
        let podcastID = PodcastID(rawValue: canonicalFeedURL)
        let episodeID = EpisodeID(rawValue: "\(canonicalFeedURL)-episode")

        return FeedSnapshot(
            podcast: Podcast(
                id: podcastID,
                feedURL: URL(string: feedURL)!,
                title: podcastTitle,
                author: "\(podcastTitle) Author",
                summary: "\(podcastTitle) Summary"
            ),
            episodes: [
                Episode(
                    id: episodeID,
                    podcastID: podcastID,
                    podcastTitle: podcastTitle,
                    title: "\(podcastTitle) Episode",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    duration: 120,
                    audioURL: URL(string: "https://example.com/audio.mp3"),
                    guid: episodeID.rawValue
                )
            ]
        )
    }

    private func opmlData(_ feeds: [(title: String, feedURL: String)]) -> Data {
        let outlines = feeds.map { feed in
            #"    <outline type="rss" text="\#(feed.title)" title="\#(feed.title)" xmlUrl="\#(feed.feedURL)" />"#
        }
        .joined(separator: "\n")

        return Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <opml version="2.0">
              <body>
            \(outlines)
              </body>
            </opml>
            """.utf8
        )
    }

    private func importedResult(from state: OPMLImportState) throws -> OPMLImportResult {
        guard case .imported(let result) = state else {
            Issue.record("Expected imported OPML state, got \(state).")
            throw OPMLImportTestError.unexpectedState
        }

        return result
    }

    private func temporaryFile(named filename: String, data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "opencast-opml-import-tests")
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appending(path: filename)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }
}

private actor StubOPMLFeedService: FeedService {
    enum Response: Sendable {
        case success(FeedSnapshot)
        case failure(String)
    }

    private var responsesByURL: [String: [Response]]
    private var requestedURLs: [String] = []

    init(responses: [String: Response]) {
        responsesByURL = responses.mapValues { [$0] }
    }

    func fetchFeed(at url: URL) async throws -> FeedSnapshot {
        let key = url.absoluteString
        requestedURLs.append(key)

        guard var responses = responsesByURL[key],
              !responses.isEmpty
        else {
            throw OPMLImportTestFeedError(message: "No stub response for \(key)")
        }

        let response = responses.removeFirst()
        responsesByURL[key] = responses

        switch response {
        case .success(let snapshot):
            return snapshot
        case .failure(let message):
            throw OPMLImportTestFeedError(message: message)
        }
    }

    func requestedURLStrings() -> [String] {
        requestedURLs
    }
}

private enum OPMLImportTestError: Error {
    case unexpectedState
}

private struct OPMLImportTestFeedError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}
