import Foundation
import Testing
@testable import OpenCastPlayback

@Suite("Streaming audio disk cache")
struct StreamingAudioDiskCacheTests {
    @Test("Unfinished byte ranges survive a new cache instance")
    func unfinishedByteRangesSurviveNewCacheInstance() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let url = URL(string: "https://example.com/audio.mp3")!
        let data = Data([1, 2, 3, 4])

        let cache = StreamingAudioDiskCache(directory: directory)
        try await cache.store(
            response(data: data, range: 0..<4, contentLength: 12),
            episodeID: "episode",
            podcastID: "podcast",
            originalURL: url
        )

        let reloadedCache = StreamingAudioDiskCache(directory: directory)
        let cached = try await reloadedCache.cachedData(
            episodeID: "episode",
            originalURL: url,
            range: 0..<4
        )
        let missing = try await reloadedCache.cachedData(
            episodeID: "episode",
            originalURL: url,
            range: 4..<8
        )

        #expect(cached == data)
        #expect(missing == nil)
    }

    @Test("Missing validators and changed validators are rejected")
    func missingValidatorsAndChangedValidatorsAreRejected() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let url = URL(string: "https://example.com/audio.mp3")!
        let cache = StreamingAudioDiskCache(directory: directory)

        await #expect(throws: StreamingAudioCacheError.missingValidator) {
            try await cache.store(
                response(data: Data([1]), range: 0..<1, contentLength: 4, etag: nil, lastModified: nil),
                episodeID: "episode",
                podcastID: "podcast",
                originalURL: url
            )
        }

        try await cache.store(
            response(data: Data([1, 2]), range: 0..<2, contentLength: 4, etag: #""one""#),
            episodeID: "episode",
            podcastID: "podcast",
            originalURL: url
        )

        await #expect(throws: StreamingAudioCacheError.validatorChanged) {
            try await cache.store(
                response(data: Data([3, 4]), range: 2..<4, contentLength: 4, etag: #""two""#),
                episodeID: "episode",
                podcastID: "podcast",
                originalURL: url
            )
        }
    }

    @Test("Completed entries prune before unfinished entries")
    func completedEntriesPruneBeforeUnfinishedEntries() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let cache = StreamingAudioDiskCache(directory: directory)
        let completedURL = URL(string: "https://example.com/completed.mp3")!
        let unfinishedURL = URL(string: "https://example.com/unfinished.mp3")!

        try await cache.store(
            response(data: Data([1, 2, 3, 4]), range: 0..<4, contentLength: 4),
            episodeID: "completed",
            podcastID: "podcast",
            originalURL: completedURL,
            now: Date(timeIntervalSince1970: 1)
        )
        try await cache.store(
            response(data: Data([5, 6, 7, 8]), range: 0..<4, contentLength: 8),
            episodeID: "unfinished",
            podcastID: "podcast",
            originalURL: unfinishedURL,
            now: Date(timeIntervalSince1970: 2)
        )

        try await cache.prune(byteBudget: 4)

        #expect(try await cache.manifest(episodeID: "completed", originalURL: completedURL) == nil)
        #expect(try await cache.manifest(episodeID: "unfinished", originalURL: unfinishedURL) != nil)
    }

    @Test("Cache hit returns metadata and throttles last access writes")
    func cacheHitReturnsMetadataAndThrottlesLastAccessWrites() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let url = URL(string: "https://example.com/audio.mp3")!
        let cache = StreamingAudioDiskCache(directory: directory)
        let storedAt = Date(timeIntervalSince1970: 1_000)

        try await cache.store(
            response(data: Data([1, 2, 3, 4]), range: 0..<4, contentLength: 4),
            episodeID: "episode",
            podcastID: "podcast",
            originalURL: url,
            now: storedAt
        )

        let firstHit = try await cache.cachedResponse(
            episodeID: "episode",
            originalURL: url,
            range: 0..<2,
            now: storedAt.addingTimeInterval(10)
        )
        let unchangedManifest = try await #require(cache.manifest(episodeID: "episode", originalURL: url))

        let secondHit = try await cache.cachedResponse(
            episodeID: "episode",
            originalURL: url,
            range: 2..<4,
            now: storedAt.addingTimeInterval(31)
        )
        let updatedManifest = try await #require(cache.manifest(episodeID: "episode", originalURL: url))

        #expect(firstHit?.data == Data([1, 2]))
        #expect(firstHit?.contentLength == 4)
        #expect(firstHit?.mimeType == "audio/mpeg")
        #expect(unchangedManifest.lastAccess == storedAt)
        #expect(secondHit?.data == Data([3, 4]))
        #expect(updatedManifest.lastAccess == storedAt.addingTimeInterval(31))
    }

    @Test("Maintenance removes entries by podcast and summarizes files")
    func maintenanceRemovesEntriesByPodcastAndSummarizesFiles() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let removedURL = URL(string: "https://example.com/removed.mp3")!
        let keptURL = URL(string: "https://example.com/kept.mp3")!
        let cache = StreamingAudioDiskCache(directory: directory)
        let maintenance = StreamingAudioCacheMaintenance(directory: directory)

        try await cache.store(
            response(data: Data([1, 2]), range: 0..<2, contentLength: 4),
            episodeID: "removed",
            podcastID: "removed-podcast",
            originalURL: removedURL
        )
        try await cache.store(
            response(data: Data([3, 4]), range: 0..<2, contentLength: 4),
            episodeID: "kept",
            podcastID: "kept-podcast",
            originalURL: keptURL
        )

        try await maintenance.remove(podcastID: "removed-podcast")
        let summary = try await maintenance.summary()

        #expect(try await cache.manifest(episodeID: "removed", originalURL: removedURL) == nil)
        #expect(try await cache.manifest(episodeID: "kept", originalURL: keptURL) != nil)
        #expect(summary.byteCount > 0)
        #expect(summary.fileCount == 2)
    }

    @Test("Maintenance skips corrupt manifests during targeted removal")
    func maintenanceSkipsCorruptManifestsDuringTargetedRemoval() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let corruptDirectory = directory.appending(path: "corrupt", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: corruptDirectory.appending(path: "manifest.json"), options: .atomic)
        try Data([1, 2, 3]).write(to: corruptDirectory.appending(path: "audio.data"), options: .atomic)

        let maintenance = StreamingAudioCacheMaintenance(directory: directory)

        try await maintenance.remove(podcastID: "missing")
        let summary = try await maintenance.summary()

        #expect(FileManager.default.fileExists(atPath: corruptDirectory.path))
        #expect(summary.fileCount == 2)
    }

    @Test("Policy only admits enabled HTTP non-HLS audio")
    func policyOnlyAdmitsEnabledHTTPNonHLSAudio() {
        let directory = FileManager.default.temporaryDirectory
        let enabled = StreamingAudioCacheConfiguration(isEnabled: true, directory: directory)
        let disabled = StreamingAudioCacheConfiguration(isEnabled: false, directory: directory)

        #expect(StreamingAudioCachePolicy.isEligible(
            URL(string: "https://example.com/audio.mp3")!,
            configuration: enabled
        ))
        #expect(!StreamingAudioCachePolicy.isEligible(
            URL(string: "https://example.com/audio.mp3")!,
            configuration: disabled
        ))
        #expect(!StreamingAudioCachePolicy.isEligible(
            URL(fileURLWithPath: "/tmp/audio.mp3"),
            configuration: enabled
        ))
        #expect(!StreamingAudioCachePolicy.isEligible(
            URL(string: "https://example.com/playlist.m3u8")!,
            configuration: enabled
        ))
    }

    private func response(
        data: Data,
        range: Range<Int64>,
        contentLength: Int64,
        etag: String? = #""fixture""#,
        lastModified: String? = nil,
        acceptsRanges: Bool = true
    ) -> StreamingAudioRangeResponse {
        StreamingAudioRangeResponse(
            data: data,
            range: range,
            metadata: StreamingAudioRangeMetadata(
                contentLength: contentLength,
                mimeType: "audio/mpeg",
                etag: etag,
                lastModified: lastModified,
                acceptsRanges: acceptsRanges,
                responseURL: URL(string: "https://example.com/audio.mp3")
            )
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastStreamingAudioDiskCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
