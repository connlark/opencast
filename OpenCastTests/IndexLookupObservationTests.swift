import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

/// The O(1)-index lookups pair an @ObservationIgnored dictionary with a
/// tracked read so a body whose lookup missed still invalidates when the
/// record or episode appears (audit §7 / §17 shape; DownloadStore has its
/// own regression test).
@MainActor
@Suite("Index lookup observation guards")
struct IndexLookupObservationTests {
    @Test("Ad-analysis record lookup registers a dependency on the miss path")
    func adAnalysisLookupMissInvalidates() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = EpisodeAdAnalysisStore(
            client: IdleAdAnalysisClient(),
            fileStore: EpisodeAdAnalysisFileStore(baseDirectory: try makeTemporaryDirectory())
        )
        store.load(modelContext: context)

        await confirmation("nil lookup invalidates when the record appears") { invalidated in
            withObservationTracking {
                #expect(store.record(for: "missing") == nil)
            } onChange: {
                invalidated()
            }
            context.insert(EpisodeAdAnalysisRecord(episodeID: "missing", podcastID: "https://example.com/feed.xml", state: .failed))
            store.load(modelContext: context)
        }
        #expect(store.record(for: "missing") != nil)
    }

    @Test("Transcript-analysis record lookup registers a dependency on the miss path")
    func transcriptAnalysisLookupMissInvalidates() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = EpisodeTranscriptAnalysisStore(
            client: IdleTranscriptAnalysisClient(),
            fileStore: EpisodeTranscriptAnalysisFileStore(baseDirectory: try makeTemporaryDirectory())
        )
        store.load(modelContext: context)

        await confirmation("nil lookup invalidates when the record appears") { invalidated in
            withObservationTracking {
                #expect(store.record(for: "missing") == nil)
            } onChange: {
                invalidated()
            }
            context.insert(EpisodeTranscriptAnalysisRecord(episodeID: "missing", podcastID: "https://example.com/feed.xml", state: .failed))
            store.load(modelContext: context)
        }
        #expect(store.record(for: "missing") != nil)
    }

    @Test("Transcript record lookup registers a dependency on the miss path")
    func transcriptionLookupMissInvalidates() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let store = EpisodeTranscriptionStore(
            fileStore: EpisodeTranscriptFileStore(baseDirectory: try makeTemporaryDirectory())
        )
        store.load(modelContext: context)

        await confirmation("nil lookup invalidates when the record appears") { invalidated in
            withObservationTracking {
                #expect(store.record(for: "missing") == nil)
            } onChange: {
                invalidated()
            }
            context.insert(EpisodeTranscriptRecord(
                episodeID: "missing",
                podcastID: "https://example.com/feed.xml",
                sourceAudioURL: "https://example.com/missing.mp3",
                state: .failed
            ))
            store.load(modelContext: context)
        }
        #expect(store.record(for: "missing") != nil)
    }

    @Test("Library episode lookups register a dependency on the miss path")
    func libraryEpisodeLookupMissInvalidates() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let feedURL = "https://example.com/lookup.xml"
        let localCache = SQLiteLocalLibraryCacheStore.inMemory()
        let store = LibraryStore(feedService: IdleFeedService(), localCache: localCache)
        context.insert(SubscriptionRecord(feedURL: feedURL, title: "Lookup Show"))
        try context.save()
        await store.load(modelContext: context)
        let snapshot = makeSnapshot(feedURL: feedURL, guid: "lookup-guid")
        let episodeID = snapshot.episodes[0].id.rawValue

        await confirmation("nil lookups invalidate when the episode appears") { invalidated in
            withObservationTracking {
                #expect(store.episode(with: episodeID) == nil)
                #expect(store.episodes(forPodcastID: feedURL).isEmpty)
            } onChange: {
                invalidated()
            }
            try? await localCache.upsertCache(from: snapshot, refreshedAt: .now)
            await store.load(modelContext: context)
        }
        #expect(store.episode(with: episodeID) != nil)
        #expect(store.episodes(forPodcastID: feedURL).count == 1)
    }

    private func makeSnapshot(feedURL: String, guid: String) -> FeedSnapshot {
        let url = URL(string: feedURL)!
        let audioURL = URL(string: "https://cdn.example.com/lookup.mp3")
        return FeedSnapshot(
            podcast: Podcast(id: URLCanonicalizer.podcastID(for: url), feedURL: url, title: "Lookup Show"),
            episodes: [
                Episode(
                    id: EpisodeIdentity.makeID(
                        feedURL: url,
                        guid: guid,
                        audioURL: audioURL,
                        title: "Lookup Episode",
                        publishedAt: Date(timeIntervalSince1970: 1_700_000_100)
                    ),
                    podcastID: URLCanonicalizer.podcastID(for: url),
                    podcastTitle: "Lookup Show",
                    title: "Lookup Episode",
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_100),
                    duration: 120,
                    audioURL: audioURL,
                    guid: guid
                )
            ]
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "IndexLookupObservationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct IdleAdAnalysisClient: EpisodeAdAnalysisClient {
    func analyze(_ request: EpisodeAdAnalysisAPIRequest) async throws -> EpisodeAdAnalysisSubmitOutcome {
        throw CancellationError()
    }

    func pollJob(id: String) async throws -> EpisodeAdAnalysisJobPollOutcome {
        throw CancellationError()
    }
}

private struct IdleTranscriptAnalysisClient: EpisodeTranscriptAnalysisClient {
    func analyze(_ request: EpisodeTranscriptAnalysisAPIRequest) async throws -> EpisodeTranscriptAnalysisSubmitOutcome {
        throw CancellationError()
    }

    func pollJob(id: String) async throws -> EpisodeTranscriptAnalysisJobPollOutcome {
        throw CancellationError()
    }
}

private struct IdleFeedService: FeedService {
    func fetchFeed(at url: URL) async throws -> FeedSnapshot {
        throw CancellationError()
    }
}
