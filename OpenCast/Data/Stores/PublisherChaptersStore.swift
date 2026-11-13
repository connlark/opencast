import Foundation
import OpenCastCore

/// Feed-declared (`podcast:chapters`) chapters documents, fetched on demand
/// and kept in the episode's cache row. Fail-open like the rest of the
/// chapters surfaces: a document that cannot be read is never an error, it
/// is retried after a backoff, and a stored entry keeps answering while it
/// cannot be refreshed (stale beats blank).
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

    /// The episode's chapters from its declared document. Cache-first; one
    /// shared fetch per episode and URL, which a cancelled caller stops
    /// waiting for but never stops.
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

    /// Cache-only (never fetches): a stored entry for `documentURL` with zero chapters.
    func isDocumentKnownEmpty(episodeID: String, documentURL: String) async -> Bool {
        await storedEntry(episodeID: episodeID, documentURL: documentURL)?.chapters.isEmpty == true
    }

    /// Awaits the episode's in-flight fetches, if any. Test hook.
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
            // A feed refresh may have moved the declaration while this fetch
            // ran: the entry still answers the callers that asked for its
            // URL, but must not replace the newer URL's.
            if (try? await localCache.episodeDetail(episodeID: key.episodeID))?.chaptersURL == key.documentURL {
                try? await localCache.storePublisherChapters(entry, episodeID: key.episodeID)
            }
            return PublisherChaptersResolution(entry)
        }
        fetchTasks[key] = fetch
        return fetch
    }

    /// nil on any failure: a URL that is not http(s), transport, a non-2xx
    /// status, an oversized body, or a document that does not decode.
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
