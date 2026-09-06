import CryptoKit
import Foundation
import Testing
@testable import OpenCastCore

@Suite(.serialized)
struct PreparedFeedTests {
    private let feedURL = URL(string: "https://example.com/feed.xml")!

    @Test func preparedMatchesMaterializedIdentityAndRecovery() async throws {
        let feeds = [
            """
            <rss><channel><title>A &amp; B</title>
            <item><title>New</title><guid>reused</guid><pubDate>Sat, 05 Sep 2026 19:00:00 +0000</pubDate><enclosure url="https://example.com/new.mp3"/><description><![CDATA[<p>Full & exact</p>]]></description></item>
            <item><title>Old</title><guid>reused</guid><pubDate>Wed, 25 Jul 2018 19:12:59 +0000</pubDate><enclosure url="https://example.com/old.mp3"/></item>
            </channel></rss>
            """,
            "<rss><channel><title>A & B &mdash; C</title><item><title>One &hellip;</title><guid>1</guid></item></channel></rss>",
            "<rss><channel><title>Partial</title><item><title>One</title><guid>1</guid></item><item><title>Broken"
        ]
        for xml in feeds {
            let url = try temporaryXML(Data(xml.utf8))
            defer { try? FileManager.default.removeItem(at: url) }
            let prepared = try await RSSFeedParser().prepare(fileURL: url, feedURL: feedURL)
            let expected = try RSSFeedParser().parse(data: Data(xml.utf8), feedURL: feedURL)
            let actual = try prepared.materialized()
            #expect(actual.podcast == expected.podcast)
            #expect(actual.episodes == expected.episodes)
            #expect(actual.isSalvaged == expected.isSalvaged)
            #expect(try prepared.materialized().episodes == actual.episodes)
        }
    }

    @Test func preparedPreservesAllFixtureMetadata() async throws {
        let directory = Bundle.module.resourceURL!
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { ["xml", "rss"].contains($0.pathExtension) }
        for url in files {
            let data = try Data(contentsOf: url)
            guard let expected = try? RSSFeedParser().parse(data: data, feedURL: feedURL) else { continue }
            let prepared = try await RSSFeedParser().prepare(fileURL: url, feedURL: feedURL)
            let actual = try prepared.materialized()
            #expect(actual.podcast == expected.podcast, "\(url.lastPathComponent)")
            #expect(actual.episodes == expected.episodes, "\(url.lastPathComponent)")
            #expect(actual.isSalvaged == expected.isSalvaged, "\(url.lastPathComponent)")
        }
    }

    @Test func rawItemLimitAndBoundedReplay() async throws {
        for count in [4_096, 10_000, 100_000, 100_001] {
            let url = try temporaryXML(Data())
            defer { try? FileManager.default.removeItem(at: url) }
            let handle = try FileHandle(forWritingTo: url)
            try handle.write(contentsOf: Data("<rss><channel><title>Stress</title>".utf8))
            for index in 0..<count {
                try handle.write(contentsOf: Data("<item><guid>\(index)</guid><title>Episode \(index)</title></item>".utf8))
            }
            try handle.write(contentsOf: Data("</channel></rss>".utf8))
            try handle.close()
            let result = try await RSSFeedParser().prepare(fileURL: url, feedURL: feedURL)
            #expect(result.episodeCount == min(count, FeedResourcePolicy.maximumItems))
            #expect(result.completeness.isComplete == (count <= FeedResourcePolicy.maximumItems))
            var read = 0
            try result.episodes.forEachBatch { batch in
                #expect(batch.count <= 256)
                read += batch.count
            }
            #expect(read == result.episodeCount)
        }
    }

    @Test func replayBatchBudgetIncludesLargeIdentityFields() throws {
        let episodes = (0..<3).map { index in
            Episode(id: EpisodeID(rawValue: "id-\(index)"), podcastID: PodcastID(rawValue: feedURL.absoluteString),
                    podcastTitle: "Show", title: "Episode", guid: String(repeating: "g", count: 700_000) + "\(index)")
        }
        let prepared = try PreparedFeed(snapshot: FeedSnapshot(
            podcast: Podcast(id: PodcastID(rawValue: feedURL.absoluteString), feedURL: feedURL, title: "Show"), episodes: episodes))
        var batchSizes: [Int] = []
        try prepared.episodes.forEachBatch { batchSizes.append($0.count) }
        #expect(batchSizes == [1, 1, 1])
    }

    @Test func recoveryPreservesUnicodeAcrossEncodedChunks() async throws {
        for (name, encoding) in [("UTF-8", String.Encoding.utf8), ("UTF-16LE", .utf16LittleEndian),
                                  ("UTF-16BE", .utf16BigEndian), ("UTF-32LE", .utf32LittleEndian),
                                  ("UTF-32BE", .utf32BigEndian), ("ISO-8859-1", .isoLatin1)] {
            let text = name == "ISO-8859-1" ? "café" : "café 🎧 日本語"
            let notes = String(repeating: text, count: 9_000)
            for recover in [false, true] {
                let title = recover ? "One &mdash; Two" : "One &#8212; Two"
                let xml = "<?xml version=\"1.0\" encoding=\"\(name)\"?><rss><channel><title>\(title)</title><item><guid>1</guid><description><![CDATA[\(notes)]]></description></item></channel></rss>"
                let url = try temporaryXML(#require(xml.data(using: encoding)))
                defer { try? FileManager.default.removeItem(at: url) }
                let result = try await RSSFeedParser().prepare(fileURL: url, feedURL: feedURL)
                #expect(result.completeness == .complete, "\(name), recovery: \(recover)")
                #expect(result.podcast.title == "One — Two")
                let episode = try #require(result.materialized().episodes.first)
                #expect(episode.summary?.utf8.count == notes.utf8.count, "\(name)")
            }
        }
    }

    @Test func cancelledQueuedPreparationDoesNotConsumeAdmission() async throws {
        let gate = FeedPreparationGate()
        try await gate.acquire()
        try await gate.acquire()
        let waiting = Task { try await gate.acquire() }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        await gate.release()
        await gate.release()
        try await gate.acquire()
        try await gate.acquire()
        await gate.release()
        await gate.release()
    }

    @Test func interruptedFeedIsExplicitlyPartialAndCancellationNeverSalvages() async throws {
        let xml = "<rss><channel><item><guid>1</guid><title>Usable</title></item><item>"
        let url = try temporaryXML(Data(xml.utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let reason = FeedIncompleteReason.interruptedTransfer("Connection lost")
        let prepared = try await RSSFeedParser().prepare(fileURL: url, feedURL: feedURL, transferIssue: reason)
        #expect(prepared.episodeCount == 1)
        #expect(prepared.completeness == .partial(reason))
        let task = Task {
            try Task.checkCancellation()
            return try await RSSFeedParser().prepare(fileURL: url, feedURL: feedURL)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func cancelledServiceQueueNeverStartsThirdTransfer() async throws {
        let client = SuspendedFeedTestClient()
        let service = DefaultFeedService(httpClient: client)
        let first = Task { try await service.prepareFeed(at: feedURL) }
        let second = Task { try await service.prepareFeed(at: feedURL) }
        defer { first.cancel(); second.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await client.started < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await client.started == 2)
        let queued = Task { try await service.prepareFeed(at: feedURL) }
        try await Task.sleep(for: .milliseconds(20))
        queued.cancel()
        await #expect(throws: CancellationError.self) { _ = try await queued.value }
        #expect(await client.started == 2)
        first.cancel()
        second.cancel()
        await #expect(throws: CancellationError.self) { _ = try await first.value }
        await #expect(throws: CancellationError.self) { _ = try await second.value }
    }

    @Test func oversizedCDATAAndDepthKeepOnlyCompletedItems() async throws {
        let prefix = "<rss><channel><item><guid>safe</guid></item>"
        let cases = [
            ("<item><description><![CDATA[" + String(repeating: "x", count: FeedResourcePolicy.maximumFieldBytes + 1)
                + "]]></description></item>", FeedIncompleteReason.fieldLimit),
            ("<item>" + String(repeating: "<nested>", count: 51), FeedIncompleteReason.depthLimit)
        ]
        for (tail, reason) in cases {
            let url = try temporaryXML(Data((prefix + tail + "</channel></rss>").utf8))
            defer { try? FileManager.default.removeItem(at: url) }
            let prepared = try await RSSFeedParser().prepare(fileURL: url, feedURL: feedURL)
            #expect(prepared.episodeCount == 1)
            #expect(prepared.completeness == .partial(reason))
        }
    }

    @Test func itemAttributesCountTowardThePerItemBudget() async throws {
        let halfBudget = String(repeating: "x", count: 8 * 1_024 * 1_024)
        let xml = "<rss><channel><item><guid>safe</guid></item><item data=\"\(halfBudget)\"><guid>over</guid><description>\(halfBudget)</description></item></channel></rss>"
        let url = try temporaryXML(Data(xml.utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await RSSFeedParser().prepare(fileURL: url, feedURL: feedURL)
        #expect(result.episodeCount == 1)
        #expect(result.completeness == .partial(.itemTextLimit))
    }

    @Test func cancellationStopsParserAfterCompletedItems() async throws {
        let items = (0..<30).map { "<item><guid>\($0)</guid><description>Notes</description></item>" }.joined()
        let url = try temporaryXML(Data("<rss><channel>\(items)</channel></rss>".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let task = Task { try await Self.cancelActiveParser(url, feedURL: feedURL) }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @concurrent
    private static func cancelActiveParser(_ url: URL, feedURL: URL) async throws {
        var completed = 0
        let delegate = FeedXMLParserDelegate(feedURL: feedURL, fallbackCDATAEncoding: nil) { _ in
            completed += 1
            if completed == 5 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let stream = try FeedXMLInputStream(fileURL: url)
        defer { stream.close() }
        let parser = XMLParser(stream: stream)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        #expect(!parser.parse())
        #expect(completed == 5)
        #expect(delegate.wasCancelled)
        try Task.checkCancellation()
    }

    @Test func decodedFileBoundaries() async throws {
        // Reuse one generated file; comments keep the field/item guards out of
        // this transfer-envelope test. No large payload is embedded in resources.
        let prefix = Data("<rss><channel><item><guid>1</guid></item>".utf8)
        let suffix = Data("</channel></rss>".utf8)
        for mib in [8, 12, 64, 128] {
            for excess in [0, 1] {
                let count = mib * 1_024 * 1_024 + excess
                let url = try temporaryXML(prefix)
                defer { try? FileManager.default.removeItem(at: url) }
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                var remaining = count - prefix.count - suffix.count
                let comment = Data(("<!--" + String(repeating: "x", count: 65_536 - 7) + "-->").utf8)
                while remaining >= comment.count {
                    try handle.write(contentsOf: comment)
                    remaining -= comment.count
                }
                try handle.write(contentsOf: Data(repeating: 32, count: remaining))
                try handle.write(contentsOf: suffix)
                try handle.close()
                let prepared = try await RSSFeedParser().prepare(fileURL: url, feedURL: feedURL)
                #expect(prepared.episodeCount == 1)
                #expect(prepared.completeness.isComplete == (count <= FeedResourcePolicy.maximumDecodedBytes))
                if count > FeedResourcePolicy.maximumDecodedBytes {
                    #expect(prepared.completeness.reason == .decodedByteLimit)
                }
            }
        }
    }

    @Test func pinnedLargeCaptures() async throws {
        // Explicit opt-in: public captures are never shipped in test resources.
        guard ProcessInfo.processInfo.environment["OPENCAST_LARGE_FEED_CAPTURES"] == "1" else { return }
        let captures = [
            ("herd", 13_753, "a4e08c4d4f02eb0a22aa8e367b3b473bed01240a789c9ed05838827c9598241b"),
            ("greenfield", 1_819, "139a121b5914a15ecc1d8ae06221368574b85c09af2d96456c8b3e731237d85d"),
            ("eofire", 4_559, "06e4bdfea5536272959b4dccfb7d1e054991852811c0e7cd8ffd167fb9c83513"),
            ("changelog", 2_391, "459df2c545c933d9d51d8a5b94024ab4dd4de53ea64277ba5edf0e8d13315132")
        ]
        for (name, count, hash) in captures {
            let url = URL(fileURLWithPath: "/private/tmp/opencast-feed-research-\(name).xml")
            let handle = try FileHandle(forReadingFrom: url)
            var digest = SHA256()
            while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty { digest.update(data: chunk) }
            try handle.close()
            #expect(digest.finalize().feedHex == hash)
            let start = ContinuousClock.now
            let result = try await RSSFeedParser().prepare(fileURL: url, feedURL: feedURL)
            #expect(result.completeness == .complete)
            #expect(result.episodeCount == count)
            var first: Episode?
            var last: Episode?
            var total = 0
            try result.episodes.forEachBatch { batch in
                if first == nil { first = batch.first }
                last = batch.last
                total += batch.count
            }
            #expect(total == count)
            if name == "herd" {
                #expect(first?.guid == "0da1096b-df2b-4e30-bd53-b4bb014cb8b0")
                #expect(last?.guid == "gid://art19-episode-locator/V0/0WGAJxonQKMQqXd0t7ozDLBS4rMzcPLEauzEX3ZVnlE")
            }
            print("Capture \(name): \(total) episodes, prepare/replay \(start.duration(to: .now))")
        }
    }

    private func temporaryXML(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("feed-test-\(UUID()).xml")
        try data.write(to: url)
        return url
    }
}

private actor SuspendedFeedTestClient: OpenCastHTTPClient {
    private(set) var started = 0

    func data(for _: URLRequest) async throws -> OpenCastHTTPResult {
        started += 1
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
}
