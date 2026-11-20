import Foundation
import OpenCastCore

final class PublisherChaptersStore {
    nonisolated static let documentByteLimit = 2 * 1024 * 1024
    nonisolated static let requestTimeout: TimeInterval = 15
    nonisolated static let freshnessInterval: TimeInterval = 7 * 24 * 60 * 60
    nonisolated static let failureBackoff: TimeInterval = 10 * 60

    private nonisolated struct FetchKey: Hashable {
        let episodeID: String
        let documentURL: String
    }

    private let httpClient: any OpenCastHTTPClient
    private let localCache: any LocalLibraryCacheStore
    private let now: @Sendable () -> Date
    private var fetchTasks: [FetchKey: Task<PublisherChaptersResolution, Never>] = [:]
    /// In memory only: a relaunch retries every failed document once.
    private var failureBackoffEnds: [FetchKey: Date] = [:]

    init(
        httpClient: any OpenCastHTTPClient,
        localCache: any LocalLibraryCacheStore,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.httpClient = httpClient
        self.localCache = localCache
        self.now = now
    }

    /// One shared fetch per episode and URL; a cancelled caller stops waiting for it but never
    /// stops it.
    func resolve(episodeID: String, documentURL: String) async -> PublisherChaptersResolution {
        let key = FetchKey(episodeID: episodeID, documentURL: documentURL)
        if let fetch = fetchTasks[key] {
            return await outcome(of: fetch)
        }

        let stored = await storedEntry(episodeID: episodeID, documentURL: documentURL)
        if let stored, now().timeIntervalSince(stored.fetchedAt) < Self.freshnessInterval {
            return PublisherChaptersResolution(stored)
        }
        if let backoffEnd = failureBackoffEnds[key], now() < backoffEnd {
            return PublisherChaptersResolution(stored)
        }

        // Another caller may have started the fetch while this one read the cache.
        let fetch = fetchTasks[key] ?? startFetch(key, fallback: stored)
        return await outcome(of: fetch)
    }

    /// What the cache holds, whatever URL it came from. Never fetches.
    func cachedEntry(episodeID: String) async -> PublisherChaptersCacheEntry? {
        try? await localCache.publisherChapters(episodeID: episodeID)
    }

    func isDocumentKnownEmpty(episodeID: String, documentURL: String) async -> Bool {
        await storedEntry(episodeID: episodeID, documentURL: documentURL)?.chapters.isEmpty == true
    }

    func waitForFetch(episodeID: String) async {
        for (key, fetch) in fetchTasks where key.episodeID == episodeID {
            _ = await fetch.value
        }
    }

    private func storedEntry(episodeID: String, documentURL: String) async -> PublisherChaptersCacheEntry? {
        guard let entry = await cachedEntry(episodeID: episodeID), entry.sourceURL == documentURL else {
            return nil
        }
        return entry
    }

    private func outcome(of fetch: Task<PublisherChaptersResolution, Never>) async -> PublisherChaptersResolution {
        let resolution = await fetch.value
        return Task.isCancelled ? .unavailable : resolution
    }

    /// The task, not its callers, stores the result and records a failure,
    /// so a fetch every caller abandoned still lands.
    private func startFetch(
        _ key: FetchKey,
        fallback: PublisherChaptersCacheEntry?
    ) -> Task<PublisherChaptersResolution, Never> {
        let httpClient = httpClient
        let fetch = Task {
            defer {
                fetchTasks[key] = nil
            }
            guard let chapters = await Self.fetchChapters(documentURL: key.documentURL, httpClient: httpClient) else {
                failureBackoffEnds[key] = now().addingTimeInterval(Self.failureBackoff)
                return PublisherChaptersResolution(fallback)
            }
            failureBackoffEnds[key] = nil
            let entry = PublisherChaptersCacheEntry(sourceURL: key.documentURL, chapters: chapters, fetchedAt: now())
            // A feed refresh may have moved the declaration while this ran: the entry still
            // answers its callers but must not replace the newer URL's.
            if (try? await localCache.episodeDetail(episodeID: key.episodeID))?.chaptersURL == key.documentURL {
                try? await localCache.storePublisherChapters(entry, episodeID: key.episodeID)
            }
            return PublisherChaptersResolution(entry)
        }
        fetchTasks[key] = fetch
        return fetch
    }

    @concurrent
    private static func fetchChapters(
        documentURL: String,
        httpClient: any OpenCastHTTPClient
    ) async -> [EpisodeChapter]? {
        guard let url = URL(string: documentURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else {
            return nil
        }
        let request = URLRequest(url: url, timeoutInterval: requestTimeout)
        guard let result = try? await httpClient.data(for: request, maximumBodyByteCount: documentByteLimit),
              let statusCode = result.response.statusCode,
              (200..<300).contains(statusCode)
        else {
            return nil
        }
        return try? PublisherChaptersDocumentDecoder.decode(result.data)
    }
}
