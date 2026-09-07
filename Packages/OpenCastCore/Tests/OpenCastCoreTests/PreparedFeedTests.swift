import CryptoKit
import Darwin
import Foundation
import SQLite3
import Synchronization
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
        let interactive = Task { try await gate.acquire(intent: .interactive) }
        let automatic = Task { try await gate.acquire(intent: .automatic) }
        while (await gate.queuedCounts()) != (interactive: 1, automatic: 1) {
            await Task.yield()
        }
        interactive.cancel()
        automatic.cancel()
        await #expect(throws: CancellationError.self) { try await interactive.value }
        await #expect(throws: CancellationError.self) { try await automatic.value }
        await gate.release()
        await gate.release()
        try await gate.acquire()
        try await gate.acquire()
        await gate.release()
        await gate.release()
    }

    @Test func cancellationDuringAdmissionHandoffReturnsTheSlot() async throws {
        let handoff = AsyncHandoffBarrier()
        let gate = FeedPreparationGate(handoffCheckpoint: { await handoff.pause() })
        try await gate.acquire(intent: .automatic)
        try await gate.acquire(intent: .automatic)
        let waiting = Task { try await gate.acquire(intent: .interactive) }
        while (await gate.queuedCounts()).interactive != 1 { await Task.yield() }

        await gate.release()
        await handoff.waitUntilPaused()
        waiting.cancel()
        await handoff.resume()
        await #expect(throws: CancellationError.self) { try await waiting.value }

        await gate.release()
        try await gate.acquire(intent: .automatic)
        try await gate.acquire(intent: .interactive)
        await gate.release()
        await gate.release()
    }

    @Test func interactivePreparationAdvancesAheadOfQueuedAutomaticWorkWithoutStarvingIt() async throws {
        let gate = FeedPreparationGate()
        let recorder = AdmissionRecorder()
        let hold = AdmissionHold()
        try await gate.acquire(intent: .automatic)
        try await gate.acquire(intent: .automatic)

        let queuedAutomatic = Task {
            try await gate.acquire(intent: .automatic)
            await recorder.append("automatic")
            await hold.wait(for: "automatic")
            await gate.release()
        }
        while (await gate.queuedCounts()).automatic != 1 { await Task.yield() }
        let interactives = (0..<4).map { index in
            Task {
                try await gate.acquire(intent: .interactive)
                let name = "interactive-\(index)"
                await recorder.append(name)
                await hold.wait(for: name)
                await gate.release()
            }
        }
        while (await gate.queuedCounts()).interactive != 4 { await Task.yield() }

        await gate.release()
        for expectedPrefix in ["interactive", "interactive", "interactive", "automatic"] {
            let admitted = await recorder.waitForNext()
            let recorded = await recorder.values()
            #expect(admitted.hasPrefix(expectedPrefix), "remaining admissions: \(recorded)")
            await hold.release(admitted)
        }
        let last = await recorder.waitForNext()
        #expect(last.hasPrefix("interactive"))
        await hold.release(last)
        await gate.release()
        _ = try await queuedAutomatic.value
        for task in interactives { _ = try await task.value }
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

    @Test func structuralAbortSkipsRecoveryWhileEntityRepairStillRuns() async throws {
        let structuralPasses = Mutex(0)
        let nested = try temporaryXML(Data("""
            <rss><channel><title>Nested</title><item><guid>safe</guid></item>
            <item><guid>outer</guid><item><guid>nested</guid></item></item></channel></rss>
            """.utf8))
        defer { try? FileManager.default.removeItem(at: nested) }
        let partial = try await RSSFeedParser().prepare(
            fileURL: nested,
            feedURL: feedURL,
            attemptObserver: { structuralPasses.withLock { $0 += 1 } }
        )
        #expect(structuralPasses.withLock { $0 } == 1)
        #expect(partial.episodeCount == 1)
        #expect(partial.isSalvaged)

        let recoverablePasses = Mutex(0)
        let recoverable = try temporaryXML(Data(
            "<rss><channel><title>A &mdash; B</title><item><guid>one</guid></item></channel></rss>".utf8
        ))
        defer { try? FileManager.default.removeItem(at: recoverable) }
        let complete = try await RSSFeedParser().prepare(
            fileURL: recoverable,
            feedURL: feedURL,
            attemptObserver: { recoverablePasses.withLock { $0 += 1 } }
        )
        #expect(recoverablePasses.withLock { $0 } == 2)
        #expect(complete.podcast.title == "A — B")
        #expect(complete.episodeCount == 1)
    }

    @Test func undecodableFailedRecoveryThrowsAndDiscardsItsAttempt() async throws {
        var bytes = Data("<rss><channel><title>Undecodable".utf8)
        bytes.append(0xFF)
        let url = try temporaryXML(bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        let attempts = Mutex(0)

        await #expect(throws: (any Error).self) {
            _ = try await RSSFeedParser().prepare(
                fileURL: url,
                feedURL: feedURL,
                attemptObserver: { attempts.withLock { $0 += 1 } }
            )
        }
        #expect(attempts.withLock { $0 } == 1)
        await FeedWorkspace.waitForCleanup()
    }

    @Test func lexicalDelimitersRemainContextualAcrossEveryByteAndUnicodeBoundary() async throws {
        let extensions = String(repeating: "<extension>small</extension>", count: 80)
        let body = """
            <rss hint="![CDATA[" other='![CDATA[' escaped="&lt;![CDATA["><channel>
            <title>Lexical Show</title>\(extensions)
            <item><guid>one</guid><description><![CDATA[real cdata]]></description><!--real comment--></item>
            </channel></rss>
            """
        for (name, encoding) in [
            ("UTF-8", String.Encoding.utf8),
            ("UTF-16LE", .utf16LittleEndian),
            ("UTF-16BE", .utf16BigEndian),
            ("UTF-32LE", .utf32LittleEndian),
            ("UTF-32BE", .utf32BigEndian)
        ] {
            let xml = "<?xml version=\"1.0\" encoding=\"\(name)\"?>\(body)"
            let data = try #require(xml.data(using: encoding))
            let url = try temporaryXML(data)
            defer { try? FileManager.default.removeItem(at: url) }
            let guarded = try drainGuardedFileOneByteAtATime(url, byteCount: data.count)
            #expect(guarded == data, "\(name)")
            let prepared = try await RSSFeedParser().prepare(fileURL: url, feedURL: feedURL)
            let snapshot = try prepared.materialized()
            #expect(snapshot.podcast.title == "Lexical Show", "\(name)")
            #expect(snapshot.episodes.count == 1, "\(name)")
            #expect(snapshot.episodes.first?.summary == "real cdata", "\(name)")
        }
    }

    @Test func losingParseArtifactsDisappearBeforeReplaySourceIsReleased() async throws {
        let url = try temporaryXML(Data(
            "<rss><channel><title>A &mdash; B</title><item><guid>one</guid></item></channel></rss>".utf8
        ))
        defer { try? FileManager.default.removeItem(at: url) }
        var prepared: PreparedFeed? = try await RSSFeedParser().prepare(fileURL: url, feedURL: feedURL)
        let sourceDirectory = try #require(prepared?.episodes.url.deletingLastPathComponent())
        let processDirectory = sourceDirectory.deletingLastPathComponent()
        await FeedWorkspace.waitForCleanup()
        let liveJobs = try FileManager.default.contentsOfDirectory(
            at: processDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        #expect(liveJobs.count == 1)
        #expect(
            liveJobs.first?.resolvingSymlinksInPath()
                == sourceDirectory.resolvingSymlinksInPath()
        )
        #expect(try #require(prepared).materialized().episodes.count == 1)

        prepared = nil
        await FeedWorkspace.waitForCleanup()
        #expect(!FileManager.default.fileExists(atPath: sourceDirectory.path))
    }

    @Test func stagingDatabaseReadsBlobBeforeLengthAndHandlesEmptyAndNull() throws {
        let workspace = try FeedWorkspace()
        defer { workspace.discard() }
        let database = try FeedStagingDatabase(url: workspace.file("blob.sqlite"))
        defer { database.close() }
        try database.execute("""
            CREATE TABLE blobs(value BLOB);
            INSERT INTO blobs(value) VALUES (X'');
            INSERT INTO blobs(value) VALUES (NULL);
            INSERT INTO blobs(value) VALUES (X'0102');
            """)
        let statement = try database.statement("SELECT value FROM blobs ORDER BY rowid")
        defer { sqlite3_finalize(statement) }

        #expect(try database.step(statement))
        #expect(database.data(statement, column: 0).isEmpty)
        #expect(try database.step(statement))
        #expect(database.data(statement, column: 0).isEmpty)
        #expect(try database.step(statement))
        #expect(database.data(statement, column: 0) == Data([0x01, 0x02]))
        #expect(try !database.step(statement))
    }

    @Test func abandonedSweepHonorsOwnerLocksAndCleansAfterRelease() async throws {
        let activeWorkspace = try FeedWorkspace()
        defer { activeWorkspace.discard() }
        let root = FeedWorkspace.jobsRootForTesting
        let liveDirectory = root.appendingPathComponent("test-live-\(UUID())", isDirectory: true)
        let abandonedDirectory = root.appendingPathComponent("test-abandoned-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: liveDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: abandonedDirectory, withIntermediateDirectories: false)
        try Data("live".utf8).write(to: liveDirectory.appendingPathComponent("source.xml"))
        try Data("abandoned".utf8).write(to: abandonedDirectory.appendingPathComponent("source.xml"))
        let liveLockURL = liveDirectory.appendingPathComponent(".owner.lock")
        let liveDescriptor = Darwin.open(liveLockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard liveDescriptor >= 0 else { throw CocoaError(.fileLocking) }
        guard flock(liveDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(liveDescriptor)
            throw CocoaError(.fileLocking)
        }
        defer {
            _ = flock(liveDescriptor, LOCK_UN)
            Darwin.close(liveDescriptor)
        }

        FeedWorkspace.cleanAbandonedJobs()
        await FeedWorkspace.waitForCleanup()
        #expect(FileManager.default.fileExists(atPath: liveDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: abandonedDirectory.path))

        _ = flock(liveDescriptor, LOCK_UN)
        FeedWorkspace.cleanAbandonedJobs()
        await FeedWorkspace.waitForCleanup()
        #expect(!FileManager.default.fileExists(atPath: liveDirectory.path))
    }

    @Test func secondProcessCannotSweepOrClaimALiveReplayWorkspace() async throws {
        let prepared = try PreparedFeed(snapshot: FeedSnapshot(
            podcast: Podcast(
                id: PodcastID(rawValue: feedURL.absoluteString),
                feedURL: feedURL,
                title: "Cross-process"
            ),
            episodes: [Episode(
                id: EpisodeID(rawValue: "cross-process"),
                podcastID: PodcastID(rawValue: feedURL.absoluteString),
                podcastTitle: "Cross-process",
                title: "Still replayable"
            )]
        ))
        let ownerLock = prepared.episodes.url
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".owner.lock")
        let contender = Process()
        contender.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        contender.arguments = ["-s", "-t", "0", "-k", ownerLock.path, "/usr/bin/true"]
        try contender.run()
        contender.waitUntilExit()

        #expect(contender.terminationStatus != 0)
        #expect(try prepared.materialized().episodes.map(\.id.rawValue) == ["cross-process"])
    }

    @MainActor
    @Test func releasingReplayWorkspaceNeverRunsCleanupOnMainActor() async throws {
        var prepared: PreparedFeed? = try PreparedFeed(snapshot: FeedSnapshot(
            podcast: Podcast(
                id: PodcastID(rawValue: feedURL.absoluteString),
                feedURL: feedURL,
                title: "Main actor release"
            ),
            episodes: []
        ))
        let directory = try #require(prepared?.episodes.url.deletingLastPathComponent())
        let barrier = FeedWorkspace.blockNextCleanupForTesting()
        defer { barrier.release() }

        prepared = nil
        await barrier.waitUntilReached()
        #expect(FileManager.default.fileExists(atPath: directory.path))

        barrier.release()
        await FeedWorkspace.waitForCleanup()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func workspaceCreationFailureLeavesNoReplayArtifact() async throws {
        await FeedWorkspace.waitForCleanup()
        let anchor = try FeedWorkspace()
        let ownerDirectory = anchor.directory.deletingLastPathComponent()
        guard Darwin.chmod(ownerDirectory.path, S_IRUSR | S_IXUSR) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        defer {
            _ = Darwin.chmod(ownerDirectory.path, S_IRWXU)
            anchor.discard()
        }
        let before = try FileManager.default.contentsOfDirectory(
            at: ownerDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        #expect(throws: (any Error).self) {
            _ = try PreparedFeed(snapshot: FeedSnapshot(
                podcast: Podcast(
                    id: PodcastID(rawValue: feedURL.absoluteString),
                    feedURL: feedURL,
                    title: "Disk failure"
                ),
                episodes: []
            ))
        }
        let after = try FileManager.default.contentsOfDirectory(
            at: ownerDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        #expect(Set(after) == Set(before))
    }

    @Test func optInLargeMalformedFeedMeasuresBoundedPeakDiskAndCleansUp() async throws {
        guard ProcessInfo.processInfo.environment["OPENCAST_LARGE_FEED_DISK_PROBE"] == "1" else {
            return
        }
        await FeedWorkspace.waitForCleanup()
        let sourceWorkspace = try FeedWorkspace()
        let source = sourceWorkspace.file("large-malformed.xml")
        guard FileManager.default.createFile(atPath: source.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: source)
        try output.write(contentsOf: Data("<rss><channel><title>Large malformed</title>".utf8))
        let notes = String(repeating: "bounded disk payload ", count: 28)
        for index in 0..<20_000 {
            try output.write(contentsOf: Data(
                "<item><guid>\(index)</guid><title>Episode \(index)</title><description>\(notes)</description></item>".utf8
            ))
        }
        try output.write(contentsOf: Data("<item><title>truncated".utf8))
        try output.close()

        let sampling = Mutex(true)
        let sampler = Task {
            var peak = 0
            while sampling.withLock({ $0 }) {
                peak = max(peak, Self.allocatedBytes(in: FeedWorkspace.jobsRootForTesting))
                try? await Task.sleep(for: .milliseconds(10))
            }
            return max(peak, Self.allocatedBytes(in: FeedWorkspace.jobsRootForTesting))
        }
        var prepared: PreparedFeed?
        do {
            prepared = try await RSSFeedParser().prepare(fileURL: source, feedURL: feedURL)
        } catch {
            sampling.withLock { $0 = false }
            _ = await sampler.value
            sourceWorkspace.discard()
            throw error
        }
        sampling.withLock { $0 = false }
        let peak = await sampler.value
        #expect(prepared?.episodeCount == 20_000)
        #expect(prepared?.isSalvaged == true)
        #expect(peak < FeedResourcePolicy.maximumProcessingBytes)
        print("Large malformed feed peak allocated workspace bytes: \(peak)")

        prepared = nil
        sourceWorkspace.discard()
        await FeedWorkspace.waitForCleanup()
    }

    @MainActor
    @Test func compatibilityStagingDoesNotBlockItsMainActorCaller() async throws {
        let episodes = (0..<20_000).map { index in
            Episode(
                id: EpisodeID(rawValue: "compatibility-\(index)"),
                podcastID: PodcastID(rawValue: feedURL.absoluteString),
                podcastTitle: "Compatibility",
                title: "Episode \(index)",
                guid: "guid-\(index)"
            )
        }
        let snapshot = FeedSnapshot(
            podcast: Podcast(
                id: PodcastID(rawValue: feedURL.absoluteString),
                feedURL: feedURL,
                title: "Compatibility"
            ),
            episodes: episodes
        )
        let service = CompatibilitySnapshotService(snapshot: snapshot)
        let requestFinished = Mutex(false)
        let request = Task { @MainActor in
            _ = try await (service as any FeedService).prepareFeed(at: feedURL)
            requestFinished.withLock { $0 = true }
        }
        await service.waitUntilFetched()
        await service.releaseFetch()
        await Task.yield()
        let mainActorObservedInFlight = !requestFinished.withLock { $0 }
        #expect(mainActorObservedInFlight)
        _ = try await request.value
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

    private func drainGuardedFileOneByteAtATime(_ url: URL, byteCount: Int) throws -> Data {
        let stream = try FeedXMLInputStream(
            fileURL: url,
            maximumBytes: byteCount,
            maximumFieldBytes: 64
        )
        stream.open()
        defer { stream.close() }
        var result = Data()
        var byte: UInt8 = 0
        while true {
            let count = stream.read(&byte, maxLength: 1)
            if count == 0 { break }
            if count < 0 { throw stream.streamError ?? CocoaError(.fileReadUnknown) }
            result.append(byte)
        }
        return result
    }

    private static func allocatedBytes(in root: URL) -> Int {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }
        var total = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else {
                continue
            }
            total += values.fileAllocatedSize ?? 0
        }
        return total
    }
}

private actor AdmissionRecorder {
    private var recorded: [String] = []
    private var waiters: [CheckedContinuation<String, Never>] = []

    func append(_ value: String) {
        if waiters.isEmpty {
            recorded.append(value)
        } else {
            waiters.removeFirst().resume(returning: value)
        }
    }

    func waitForNext() async -> String {
        if !recorded.isEmpty { return recorded.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func values() -> [String] { recorded }
}

private actor AdmissionHold {
    private var released: Set<String> = []
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]

    func wait(for name: String) async {
        if released.remove(name) != nil { return }
        await withCheckedContinuation { waiters[name] = $0 }
    }

    func release(_ name: String) {
        if let waiter = waiters.removeValue(forKey: name) { waiter.resume() }
        else { released.insert(name) }
    }
}

private actor AsyncHandoffBarrier {
    private var isPaused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?

    func pause() async {
        isPaused = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { release = $0 }
    }

    func waitUntilPaused() async {
        if isPaused { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func resume() {
        release?.resume()
        release = nil
    }
}

private actor CompatibilitySnapshotService: FeedService {
    private let snapshot: FeedSnapshot
    private var fetched = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var fetchRelease: CheckedContinuation<Void, Never>?

    init(snapshot: FeedSnapshot) { self.snapshot = snapshot }

    func fetchFeed(at _: URL) async throws -> FeedSnapshot {
        await withCheckedContinuation { continuation in
            fetchRelease = continuation
            fetched = true
            let waiters = waiters
            self.waiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        return snapshot
    }

    func waitUntilFetched() async {
        if fetched { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func releaseFetch() {
        fetchRelease?.resume()
        fetchRelease = nil
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
