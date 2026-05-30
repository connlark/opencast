import Foundation
import Testing
@testable import OpenCastPlayback

@Suite("Streaming audio range fetcher")
struct StreamingAudioRangeFetcherTests {
    @Test("Fetcher sends byte range headers and parses partial content")
    func fetcherSendsByteRangeHeadersAndParsesPartialContent() async throws {
        let data = Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
        let server = try HTTPFixtureServer(data: data, fileName: "audio.mp3", contentType: "audio/mpeg")
        defer {
            server.stop()
        }

        let response = try await URLSessionStreamingAudioRangeFetcher().data(for: server.url, range: 2..<6)

        #expect(response.data == Data([2, 3, 4, 5]))
        #expect(response.range == 2..<6)
        #expect(response.metadata.contentLength == 10)
        #expect(response.metadata.mimeType == "audio/mpeg")
        #expect(response.metadata.etag == #""opencast-fixture""#)
        #expect(response.metadata.acceptsRanges)
        let request = try #require(server.recordedRequests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/audio.mp3")
        #expect(request.header("range") == "bytes=2-5")
        #expect(request.byteRange == .bounded(2..<6))
    }

    @Test("Fetcher rejects servers without range support")
    func fetcherRejectsServersWithoutRangeSupport() async throws {
        let server = try HTTPFixtureServer(
            data: Data([0, 1, 2, 3]),
            fileName: "audio.mp3",
            contentType: "audio/mpeg",
            acceptsRanges: false
        )
        defer {
            server.stop()
        }

        await #expect(throws: StreamingAudioCacheError.noRangeSupport) {
            try await URLSessionStreamingAudioRangeFetcher().data(for: server.url, range: 0..<2)
        }
    }

    @Test("Fetcher rejects servers that ignore range requests")
    func fetcherRejectsServersThatIgnoreRangeRequests() async throws {
        let server = try HTTPFixtureServer(scenario: HTTPFixtureServerScenario(
            data: Data([0, 1, 2, 3]),
            fileName: "audio.mp3",
            contentType: "audio/mpeg",
            rangeBehavior: .ignored
        ))
        defer {
            server.stop()
        }

        await #expect(throws: StreamingAudioCacheError.noRangeSupport) {
            try await URLSessionStreamingAudioRangeFetcher().data(for: server.url, range: 0..<2)
        }
    }

    @Test("Fetcher rejects malformed content range responses")
    func fetcherRejectsMalformedContentRangeResponses() async throws {
        let server = try HTTPFixtureServer(scenario: HTTPFixtureServerScenario(
            data: Data([0, 1, 2, 3]),
            fileName: "audio.mp3",
            contentType: "audio/mpeg",
            rangeBehavior: .malformedContentRange("bytes nope")
        ))
        defer {
            server.stop()
        }

        await #expect(throws: StreamingAudioCacheError.invalidRange) {
            try await URLSessionStreamingAudioRangeFetcher().data(for: server.url, range: 0..<2)
        }
    }

    @Test("Fetcher reports 416 range responses")
    func fetcherReportsRangeNotSatisfiableResponses() async throws {
        let server = try HTTPFixtureServer(scenario: HTTPFixtureServerScenario(
            data: Data([0, 1, 2, 3]),
            fileName: "audio.mp3",
            contentType: "audio/mpeg",
            rangeBehavior: .rangeNotSatisfiable
        ))
        defer {
            server.stop()
        }

        await #expect(throws: StreamingAudioCacheError.unexpectedStatus(416)) {
            try await URLSessionStreamingAudioRangeFetcher().data(for: server.url, range: 0..<2)
        }
    }

    @Test("Fetcher reports redirects before cache storage")
    func fetcherReportsRedirectsBeforeCacheStorage() async throws {
        let server = try HTTPFixtureServer(scenario: HTTPFixtureServerScenario(
            data: Data([0, 1, 2, 3]),
            fileName: "audio.mp3",
            contentType: "audio/mpeg",
            redirectBehavior: .stable(path: "/cdn/audio.mp3")
        ))
        defer {
            server.stop()
        }

        await #expect(throws: StreamingAudioCacheError.redirected) {
            try await URLSessionStreamingAudioRangeFetcher().data(for: server.url, range: 0..<2)
        }

        let paths = server.recordedRequests.map(\.path)
        #expect(paths.contains("/audio.mp3"))
        #expect(paths.contains("/cdn/audio.mp3"))
    }

    @Test("Disk cache rejects stores with missing validators")
    func diskCacheRejectsStoresWithMissingValidators() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let server = try HTTPFixtureServer(scenario: HTTPFixtureServerScenario(
            data: Data([0, 1, 2, 3]),
            fileName: "audio.mp3",
            contentType: "audio/mpeg",
            validatorBehavior: .missing
        ))
        defer {
            server.stop()
        }

        let fetched = try await URLSessionStreamingAudioRangeFetcher().data(for: server.url, range: 0..<2)
        let cache = StreamingAudioDiskCache(directory: directory)

        #expect(fetched.metadata.etag == nil)
        #expect(fetched.metadata.lastModified == nil)
        await #expect(throws: StreamingAudioCacheError.missingValidator) {
            try await cache.store(
                fetched,
                episodeID: "episode",
                podcastID: "podcast",
                originalURL: server.url
            )
        }
    }

    @Test("Disk cache rejects stores when validators change between fetches")
    func diskCacheRejectsStoresWhenValidatorsChangeBetweenFetches() async throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let server = try HTTPFixtureServer(scenario: HTTPFixtureServerScenario(
            data: Data([0, 1, 2, 3]),
            fileName: "audio.mp3",
            contentType: "audio/mpeg",
            validatorBehavior: .changing(etags: [#""one""#, #""two""#], lastModifieds: [])
        ))
        defer {
            server.stop()
        }

        let cache = StreamingAudioDiskCache(directory: directory)
        let first = try await URLSessionStreamingAudioRangeFetcher().data(for: server.url, range: 0..<2)
        let second = try await URLSessionStreamingAudioRangeFetcher().data(for: server.url, range: 2..<4)

        try await cache.store(
            first,
            episodeID: "episode",
            podcastID: "podcast",
            originalURL: server.url
        )
        await #expect(throws: StreamingAudioCacheError.validatorChanged) {
            try await cache.store(
                second,
                episodeID: "episode",
                podcastID: "podcast",
                originalURL: server.url
            )
        }
    }

    @Test("Fixture server can serve an HLS playlist")
    func fixtureServerCanServeHLSPlaylist() async throws {
        let server = try HTTPFixtureServer(scenario: .hlsPlaylist())
        defer {
            server.stop()
        }

        let (data, response) = try await URLSession.shared.data(from: server.url)
        let httpResponse = try #require(response as? HTTPURLResponse)
        let body = String(decoding: data, as: UTF8.self)

        #expect(httpResponse.statusCode == 200)
        #expect(httpResponse.mimeType == "application/vnd.apple.mpegurl")
        #expect(body.contains("#EXTM3U"))
        #expect(server.recordedRequests.first?.path == "/playlist.m3u8")
    }

    @Test("Fixture server stop cancels accepted slow connections")
    func fixtureServerStopCancelsAcceptedSlowConnections() async throws {
        let server = try HTTPFixtureServer(scenario: HTTPFixtureServerScenario(
            data: Data(repeating: 1, count: 64),
            fileName: "audio.mp3",
            contentType: "audio/mpeg",
            bodyBehavior: .slow(chunkSize: 1, interval: 30)
        ))
        let task = Task {
            try await URLSession.shared.data(from: server.url)
        }

        try await waitForRecordedRequest(on: server)
        server.stop()

        do {
            _ = try await value(of: task, timeout: .seconds(2))
            Issue.record("Expected slow request to fail after server.stop().")
        } catch is TimeoutError {
            Issue.record("Timed out waiting for server.stop() to cancel the slow request.")
        } catch {
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "OpenCastStreamingAudioRangeFetcherTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitForRecordedRequest(on server: HTTPFixtureServer) async throws {
        let deadline = Date.now.addingTimeInterval(2)
        while server.recordedRequests.isEmpty && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if server.recordedRequests.isEmpty {
            Issue.record("Timed out waiting for fixture server to record a request.")
        }
    }

    private func value<Result: Sendable>(
        of task: Task<Result, any Error>,
        timeout: Duration
    ) async throws -> Result {
        try await withThrowingTaskGroup(of: Result.self) { group in
            group.addTask {
                try await task.value
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                task.cancel()
                throw TimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private struct TimeoutError: Error {
    }
}
