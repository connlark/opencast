import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Automatic downloads of new episodes")
struct PodcastAutoDownloadCoordinatorTests {
    @Test("Turning a show on downloads its newest release now and moves the watermark past it")
    func enableDownloadsNewestRelease() async throws {
        let fixture = try await AutoDownloadFixture.make(releaseDays: [1, 2, 3])
        defer { fixture.tearDown() }

        #expect(fixture.coordinator.enableAutoDownload(forPodcastID: fixture.feedURL, modelContext: fixture.context))
        #expect(fixture.watermark == AutoDownloadFixture.release(2))
        await fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.startedEpisodeIDs == [fixture.id(2)])
        #expect(fixture.watermark == AutoDownloadFixture.release(3))
        #expect(fixture.settings.autoDownloadsNewEpisodes(forPodcastID: fixture.feedURL))
    }

    @Test("Every release sharing the newest timestamp downloads on enable")
    func enableDownloadsTiedNewestReleases() async throws {
        let fixture = try await AutoDownloadFixture.make(releaseDays: [1, 2, 3, 3])
        defer { fixture.tearDown() }

        fixture.coordinator.enableAutoDownload(forPodcastID: fixture.feedURL, modelContext: fixture.context)
        await fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.startedEpisodeIDs == [fixture.id(2), fixture.id(3)])
    }

    @Test("Turning a show on skips a newest release that already has a download record")
    func enableSkipsExistingRecord() async throws {
        let fixture = try await AutoDownloadFixture.make(releaseDays: [1, 2, 3])
        defer { fixture.tearDown() }
        try await fixture.insertFailedRecord(index: 2)

        fixture.coordinator.enableAutoDownload(forPodcastID: fixture.feedURL, modelContext: fixture.context)
        await fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.startedEpisodeIDs.isEmpty)
        #expect(fixture.downloads.record(for: fixture.id(2))?.state == .failed)
        #expect(fixture.watermark == AutoDownloadFixture.release(3))
        #expect(fixture.network.callCount == 0)
    }

    @Test("A show with no released episode turns on without downloading; its first releases are capped")
    func enableWithNoEpisodes() async throws {
        let fixture = try await AutoDownloadFixture.make(releaseDays: [])
        defer { fixture.tearDown() }

        #expect(fixture.coordinator.enableAutoDownload(forPodcastID: fixture.feedURL, modelContext: fixture.context))
        await fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.watermark == .distantPast)
        #expect(fixture.startedEpisodeIDs.isEmpty)
        #expect(fixture.network.callCount == 0)

        try await fixture.publish(releaseDays: [1, 2, 3, 4, 5])
        await fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.startedEpisodeIDs == [fixture.id(2), fixture.id(3), fixture.id(4)])
        #expect(fixture.watermark == AutoDownloadFixture.release(5))
    }

    @Test("A pass downloads only releases after the watermark, then moves it")
    func passDownloadsOnlyNewReleases() async throws {
        let fixture = try await AutoDownloadFixture.make(releaseDays: [1, 2, 3])
        defer { fixture.tearDown() }
        fixture.coordinator.enableAutoDownload(forPodcastID: fixture.feedURL, modelContext: fixture.context)
        await fixture.coordinator.runPass(modelContext: fixture.context)

        try await fixture.publish(releaseDays: [1, 2, 3, 4, 5])
        await fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.startedEpisodeIDs == [fixture.id(2), fixture.id(3), fixture.id(4)])
        #expect(fixture.watermark == AutoDownloadFixture.release(5))
    }

    @Test("A pass starts at most the show's limit, and the skipped releases are never downloaded")
    func passIsCappedAtShowLimit() async throws {
        let fixture = try await AutoDownloadFixture.make(releaseDays: [1])
        defer { fixture.tearDown() }
        #expect(fixture.settings.setKeepLimitOverride(.two, forPodcastID: fixture.feedURL, modelContext: fixture.context))
        fixture.coordinator.enableAutoDownload(forPodcastID: fixture.feedURL, modelContext: fixture.context)
        await fixture.coordinator.runPass(modelContext: fixture.context)
        #expect(fixture.startedEpisodeIDs == [fixture.id(0)])

        try await fixture.publish(releaseDays: [1, 2, 3, 4, 5])
        await fixture.coordinator.runPass(modelContext: fixture.context)
        await fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.startedEpisodeIDs == [fixture.id(0), fixture.id(3), fixture.id(4)])
        #expect(fixture.watermark == AutoDownloadFixture.release(5))
    }

    @Test("With No Limit a pass starts at most three")
    func unlimitedPassIsCappedAtThree() async throws {
        let fixture = try await AutoDownloadFixture.make(releaseDays: [1])
        defer { fixture.tearDown() }
        fixture.coordinator.enableAutoDownload(forPodcastID: fixture.feedURL, modelContext: fixture.context)
        await fixture.coordinator.runPass(modelContext: fixture.context)

        try await fixture.publish(releaseDays: [1, 2, 3, 4, 5, 6])
        await fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(PodcastAutoDownloadCoordinator.unlimitedBatchCap == 3)
        #expect(fixture.startedEpisodeIDs == [fixture.id(0), fixture.id(3), fixture.id(4), fixture.id(5)])
    }

    @Test("Future-dated episodes are not released yet and never move the watermark")
    func futureDatedEpisodesWait() async throws {
        let fixture = try await AutoDownloadFixture.make(releaseDays: [1, 2, 31])
        defer { fixture.tearDown() }

        fixture.coordinator.enableAutoDownload(forPodcastID: fixture.feedURL, modelContext: fixture.context)
        #expect(fixture.watermark == AutoDownloadFixture.release(1))
        await fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.startedEpisodeIDs == [fixture.id(1)])
        #expect(fixture.watermark == AutoDownloadFixture.release(2))

        fixture.now = AutoDownloadFixture.release(32)
        await fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.startedEpisodeIDs == [fixture.id(1), fixture.id(2)])
        #expect(fixture.watermark == AutoDownloadFixture.release(31))
    }

    @Test("Any existing download record keeps a new release from downloading automatically")
    func existingRecordBlocksCandidate() async throws {
        let fixture = try await AutoDownloadFixture.make(releaseDays: [1, 2, 3])
        defer { fixture.tearDown() }
        try await fixture.insertFailedRecord(index: 2)
        #expect(fixture.settings.setAutoDownloadsNewEpisodes(
            true,
            forPodcastID: fixture.feedURL,
            watermark: AutoDownloadFixture.release(1),
            modelContext: fixture.context
        ))

        await fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.startedEpisodeIDs == [fixture.id(1)])
        #expect(fixture.downloads.record(for: fixture.id(2))?.state == .failed)
        #expect(fixture.watermark == AutoDownloadFixture.release(3))
    }

    @Test(
        "Off Wi-Fi a pass keeps the watermark and the next Wi-Fi pass starts the same episodes",
        arguments: [
            NetworkPathSnapshot(isSatisfied: true, isExpensive: true, isConstrained: false),
            NetworkPathSnapshot(isSatisfied: true, isExpensive: false, isConstrained: true),
            NetworkPathSnapshot(isSatisfied: false, isExpensive: false, isConstrained: false),
        ]
    )
    func offWiFiPassDefers(path: NetworkPathSnapshot) async throws {
        let fixture = try await AutoDownloadFixture.make(releaseDays: [1, 2, 3])
        defer { fixture.tearDown() }
        fixture.network.path = path

        fixture.coordinator.enableAutoDownload(forPodcastID: fixture.feedURL, modelContext: fixture.context)
        await fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.network.callCount >= 1)
        #expect(fixture.startedEpisodeIDs.isEmpty)
        #expect(fixture.watermark == AutoDownloadFixture.release(2))

        fixture.network.path = AutoDownloadFixture.wiFi
        await fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.startedEpisodeIDs == [fixture.id(2)])
        #expect(fixture.watermark == AutoDownloadFixture.release(3))
    }

    @Test("With Wi-Fi Only off a pass never reads the network path")
    func wiFiOnlyOffIgnoresPath() async throws {
        let fixture = try await AutoDownloadFixture.make(releaseDays: [1, 2, 3])
        defer { fixture.tearDown() }
        fixture.network.path = NetworkPathSnapshot(isSatisfied: true, isExpensive: true, isConstrained: true)
        #expect(fixture.settings.setAutoDownloadsRequireWiFi(false, modelContext: fixture.context))

        fixture.coordinator.enableAutoDownload(forPodcastID: fixture.feedURL, modelContext: fixture.context)
        await fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.startedEpisodeIDs == [fixture.id(2)])
        #expect(fixture.network.callCount == 0)
    }

    @Test("Passes with nothing new neither read the network nor start anything twice")
    func idlePassesAreIdempotent() async throws {
        let fixture = try await AutoDownloadFixture.make(releaseDays: [1, 2, 3])
        defer { fixture.tearDown() }
        fixture.coordinator.enableAutoDownload(forPodcastID: fixture.feedURL, modelContext: fixture.context)
        await fixture.coordinator.runPass(modelContext: fixture.context)
        let callsAfterFirstPass = fixture.network.callCount

        await fixture.coordinator.runPass(modelContext: fixture.context)
        await fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.network.callCount == callsAfterFirstPass)
        #expect(fixture.startedEpisodeIDs == [fixture.id(2)])
        #expect(await waitUntil { fixture.downloader.requestCount == 1 })
    }

    @Test("A missing watermark heals at the newest release without downloading")
    func missingWatermarkHeals() async throws {
        let fixture = try await AutoDownloadFixture.make(releaseDays: [1, 2, 3])
        defer { fixture.tearDown() }
        #expect(fixture.settings.setAutoDownloadsNewEpisodes(true, forPodcastID: fixture.feedURL, modelContext: fixture.context))
        #expect(fixture.watermark == nil)

        await fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.startedEpisodeIDs.isEmpty)
        #expect(fixture.watermark == AutoDownloadFixture.release(3))
        #expect(fixture.network.callCount == 0)

        try await fixture.publish(releaseDays: [1, 2, 3, 4])
        await fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.startedEpisodeIDs == [fixture.id(3)])
    }

    @Test("A deleted automatic download is not downloaded again")
    func deletedDownloadStaysDeleted() async throws {
        let fixture = try await AutoDownloadFixture.make(releaseDays: [1, 2, 3])
        defer { fixture.tearDown() }
        fixture.coordinator.enableAutoDownload(forPodcastID: fixture.feedURL, modelContext: fixture.context)
        await fixture.coordinator.runPass(modelContext: fixture.context)
        fixture.downloads.cancelDownload(episodeID: fixture.id(2), modelContext: fixture.context)
        #expect(fixture.downloads.record(for: fixture.id(2)) == nil)

        await fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.downloads.record(for: fixture.id(2)) == nil)
        #expect(fixture.startedEpisodeIDs.isEmpty)
    }

    @Test("A release downloaded by hand still moves the watermark, so deleting it later can't bring it back")
    func manualDownloadMovesWatermark() async throws {
        let fixture = try await AutoDownloadFixture.make(releaseDays: [1])
        defer { fixture.tearDown() }
        fixture.coordinator.enableAutoDownload(forPodcastID: fixture.feedURL, modelContext: fixture.context)
        await fixture.coordinator.runPass(modelContext: fixture.context)
        try await fixture.publish(releaseDays: [1, 2])
        fixture.downloads.startDownload(for: try #require(fixture.episode(1)), modelContext: fixture.context)

        await fixture.coordinator.runPass(modelContext: fixture.context)
        #expect(fixture.watermark == AutoDownloadFixture.release(2))
        fixture.downloads.cancelDownload(episodeID: fixture.id(1), modelContext: fixture.context)
        await fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.downloads.record(for: fixture.id(1)) == nil)
    }

    @Test("Shows that are not subscribed are ignored")
    func unsubscribedShowsAreIgnored() async throws {
        let fixture = try await AutoDownloadFixture.make(releaseDays: [1, 2, 3], subscribes: false)
        defer { fixture.tearDown() }
        #expect(fixture.settings.setAutoDownloadsNewEpisodes(
            true,
            forPodcastID: fixture.feedURL,
            watermark: .distantPast,
            modelContext: fixture.context
        ))

        await fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.downloads.records.isEmpty)
        #expect(fixture.network.callCount == 0)
        #expect(fixture.watermark == .distantPast)
    }

    @Test("Requests during a pass coalesce into a single follow-up pass")
    func scheduledPassesCoalesce() async throws {
        let fixture = try await AutoDownloadFixture.make(releaseDays: [1, 2, 3])
        defer { fixture.tearDown() }
        // Off Wi-Fi the candidates stay, so every pass that runs reads the
        // path once; the count is the number of passes.
        fixture.network.path = NetworkPathSnapshot(isSatisfied: true, isExpensive: true, isConstrained: false)
        fixture.network.isHeld = true
        fixture.coordinator.enableAutoDownload(forPodcastID: fixture.feedURL, modelContext: fixture.context)
        #expect(await waitUntil { fixture.network.callCount == 1 })

        for _ in 0..<3 {
            fixture.coordinator.schedulePass(modelContext: fixture.context)
        }
        fixture.network.isHeld = false
        await fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.network.callCount == 2)
        #expect(fixture.startedEpisodeIDs.isEmpty)
    }

    @Test("Cancelling stops a pass at its network check with the watermark unchanged")
    func cancelStopsPassAtNetworkCheck() async throws {
        let fixture = try await AutoDownloadFixture.make(releaseDays: [1, 2, 3])
        defer { fixture.tearDown() }
        fixture.network.isHeld = true
        fixture.coordinator.enableAutoDownload(forPodcastID: fixture.feedURL, modelContext: fixture.context)
        #expect(await waitUntil { fixture.network.callCount == 1 })

        fixture.coordinator.cancelPendingWork()
        fixture.network.isHeld = false
        #expect(await waitUntil { fixture.network.returnCount == 1 })
        for _ in 0..<5 {
            await Task.yield()
        }

        #expect(fixture.startedEpisodeIDs.isEmpty)
        #expect(fixture.watermark == AutoDownloadFixture.release(2))

        await fixture.coordinator.runPass(modelContext: fixture.context)
        #expect(fixture.startedEpisodeIDs == [fixture.id(2)])
    }

    @Test("A pass cancelled before it starts never downloads, even with Wi-Fi Only off")
    func passCancelledBeforeEntryDoesNothing() async throws {
        let fixture = try await AutoDownloadFixture.make(releaseDays: [1, 2, 3])
        defer { fixture.tearDown() }
        #expect(fixture.settings.setAutoDownloadsRequireWiFi(false, modelContext: fixture.context))

        // Synchronous with the enable: the scheduled task has not run yet.
        fixture.coordinator.enableAutoDownload(forPodcastID: fixture.feedURL, modelContext: fixture.context)
        fixture.coordinator.cancelPendingWork()
        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(fixture.downloads.records.isEmpty)
        #expect(fixture.watermark == AutoDownloadFixture.release(2))
    }

    @Test("A cancelled pass never runs alongside the pass that replaces it")
    func cancelledPassNeverRunsBesideReplacement() async throws {
        let fixture = try await AutoDownloadFixture.make(releaseDays: [1, 2, 3])
        defer { fixture.tearDown() }
        fixture.network.path = NetworkPathSnapshot(isSatisfied: true, isExpensive: true, isConstrained: false)
        fixture.coordinator.enableAutoDownload(forPodcastID: fixture.feedURL, modelContext: fixture.context)
        fixture.coordinator.cancelPendingWork()

        // Off Wi-Fi each pass that runs reads the path once and starts
        // nothing, so the count is the passes run. Requests made before the
        // replacement starts coalesce into it.
        fixture.coordinator.schedulePass(modelContext: fixture.context)
        fixture.coordinator.schedulePass(modelContext: fixture.context)
        await fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.network.callCount == 1)
        #expect(fixture.downloads.records.isEmpty)
    }

    @Test("When the last active scene leaves, a pass in flight stops and requests wait for activation")
    func backgroundSuspendsPasses() async throws {
        let fixture = try await AutoDownloadFixture.make(releaseDays: [1, 2, 3])
        defer { fixture.tearDown() }
        let scene = UUID()
        fixture.coordinator.setScene(scene, isActive: true)
        fixture.network.isHeld = true
        fixture.coordinator.enableAutoDownload(forPodcastID: fixture.feedURL, modelContext: fixture.context)
        #expect(await waitUntil { fixture.network.callCount == 1 })

        fixture.coordinator.setScene(scene, isActive: false)
        fixture.network.isHeld = false
        // A launch or refresh that decided earlier the scene was active.
        fixture.coordinator.schedulePass(modelContext: fixture.context)
        await fixture.coordinator.runPass(modelContext: fixture.context)
        #expect(await waitUntil { fixture.network.returnCount == 1 })
        for _ in 0..<5 {
            await Task.yield()
        }

        #expect(fixture.network.callCount == 1)
        #expect(fixture.downloads.records.isEmpty)
        #expect(fixture.watermark == AutoDownloadFixture.release(2))

        fixture.coordinator.setScene(scene, isActive: true)
        #expect(fixture.downloads.records.isEmpty)
        await fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.startedEpisodeIDs == [fixture.id(2)])
    }

    @Test("With two windows, one going inactive leaves passes running for the active one")
    func activeSceneKeepsGateOpen() async throws {
        let fixture = try await AutoDownloadFixture.make(releaseDays: [1, 2, 3])
        defer { fixture.tearDown() }
        let windowA = UUID()
        let windowB = UUID()
        fixture.coordinator.setScene(windowA, isActive: true)
        fixture.coordinator.setScene(windowB, isActive: true)

        fixture.coordinator.setScene(windowB, isActive: false)
        #expect(fixture.coordinator.isForeground)
        fixture.coordinator.enableAutoDownload(forPodcastID: fixture.feedURL, modelContext: fixture.context)
        await fixture.coordinator.runPass(modelContext: fixture.context)
        #expect(fixture.startedEpisodeIDs == [fixture.id(2)])

        fixture.coordinator.removeScene(windowA)
        #expect(!fixture.coordinator.isForeground)
        fixture.coordinator.setScene(windowB, isActive: true)
        #expect(fixture.coordinator.isForeground)
    }

    @Test("Turning a show off through the app model deletes its flag and watermark")
    func appModelDisableClearsSettings() async throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let library = LibraryStore(localCache: SQLiteLocalLibraryCacheStore.inMemory())
        let appModel = OpenCastAppModel(
            library: library,
            currentNetworkPath: { AutoDownloadFixture.wiFi }
        )
        let feedURL = "https://example.com/app-model-auto.xml"

        #expect(appModel.setAutoDownloadsNewEpisodes(true, forPodcastID: feedURL, modelContext: context))
        #expect(appModel.downloadSettings.autoDownloadWatermark(forPodcastID: feedURL) == .distantPast)
        #expect(appModel.setAutoDownloadsNewEpisodes(false, forPodcastID: feedURL, modelContext: context))

        #expect(!appModel.downloadSettings.autoDownloadsNewEpisodes(forPodcastID: feedURL))
        #expect(appModel.downloadSettings.autoDownloadWatermark(forPodcastID: feedURL) == nil)
        appModel.setAutoDownloadsScene(UUID(), isActive: false)
    }
}

@MainActor
private final class AutoDownloadFixture {
    static let base = Date(timeIntervalSince1970: 1_780_000_000)
    static let wiFi = NetworkPathSnapshot(isSatisfied: true, isExpensive: false, isConstrained: false)

    /// Day `day` after `base`; the fixture's clock starts on day 30.
    static func release(_ day: Int) -> Date {
        base.addingTimeInterval(Double(day) * 86_400)
    }

    let feedURL = "https://example.com/auto-download.xml"
    let context: ModelContext
    let cache: SQLiteLocalLibraryCacheStore
    let library: LibraryStore
    let downloader = RecordingHangingEpisodeAudioDownloader()
    let downloads: DownloadStore
    let settings = DownloadSettingsStore()
    let network = NetworkPathProbe()
    var now = AutoDownloadFixture.release(30)
    private(set) var episodes: [Episode] = []
    private(set) var coordinator: PodcastAutoDownloadCoordinator!

    private init(context: ModelContext, cache: SQLiteLocalLibraryCacheStore, fileStore: EpisodeDownloadFileStore) {
        self.context = context
        self.cache = cache
        library = LibraryStore(localCache: cache)
        downloads = DownloadStore(downloader: downloader, fileStore: fileStore)
    }

    /// Episode `i` is released on `releaseDays[i]`.
    static func make(releaseDays: [Int], subscribes: Bool = true) async throws -> AutoDownloadFixture {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PodcastAutoDownloadCoordinatorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = AutoDownloadFixture(
            context: ModelContext(container),
            cache: SQLiteLocalLibraryCacheStore.inMemory(),
            fileStore: EpisodeDownloadFileStore(baseDirectory: directory)
        )
        fixture.coordinator = PodcastAutoDownloadCoordinator(
            library: fixture.library,
            downloads: fixture.downloads,
            settings: fixture.settings,
            currentNetworkPath: { [network = fixture.network] in await network.current() },
            now: { [unowned fixture] in fixture.now }
        )
        if subscribes {
            fixture.context.insert(SubscriptionRecord(feedURL: fixture.feedURL, title: "Auto Show"))
            try fixture.context.save()
        }
        fixture.settings.load(modelContext: fixture.context)
        await fixture.downloads.load(modelContext: fixture.context)
        try await fixture.publish(releaseDays: releaseDays)
        return fixture
    }

    /// Replaces the show's cached episodes and reloads the library.
    func publish(releaseDays: [Int]) async throws {
        let url = URL(string: feedURL)!
        let podcastID = URLCanonicalizer.podcastID(for: url)
        episodes = releaseDays.enumerated().map { index, day in
            let audioURL = URL(string: "https://cdn.example.com/auto-\(index).mp3")
            let publishedAt = Self.release(day)
            return Episode(
                id: EpisodeIdentity.makeID(
                    feedURL: url,
                    guid: "auto-\(index)",
                    audioURL: audioURL,
                    title: "Episode \(index)",
                    publishedAt: publishedAt
                ),
                podcastID: podcastID,
                podcastTitle: "Auto Show",
                title: "Episode \(index)",
                publishedAt: publishedAt,
                duration: 600,
                audioURL: audioURL,
                guid: "auto-\(index)"
            )
        }
        try await cache.upsertCache(
            from: FeedSnapshot(
                podcast: Podcast(id: podcastID, feedURL: url, title: "Auto Show"),
                episodes: episodes
            ),
            refreshedAt: Self.base
        )
        await library.load(modelContext: context)
    }

    func id(_ index: Int) -> String {
        episodes[index].id.rawValue
    }

    func episode(_ index: Int) -> EpisodeListItemSnapshot? {
        library.episode(with: id(index))
    }

    var watermark: Date? {
        settings.autoDownloadWatermark(forPodcastID: feedURL)
    }

    var startedEpisodeIDs: Set<String> {
        Set(downloads.records.filter { $0.state == .downloading }.map(\.episodeID))
    }

    /// Only before any download starts: it reloads the download store, whose
    /// launch reconciliation would treat a live download as interrupted.
    func insertFailedRecord(index: Int) async throws {
        context.insert(
            EpisodeDownloadRecord(
                episodeID: id(index),
                podcastID: feedURL,
                sourceAudioURL: "https://cdn.example.com/auto-\(index).mp3",
                state: .failed,
                errorMessage: "The network connection was lost."
            )
        )
        try context.save()
        await downloads.load(modelContext: context)
    }

    func tearDown() {
        coordinator.cancelPendingWork()
        for record in downloads.records where record.state == .downloading {
            downloads.cancelDownload(episodeID: record.episodeID, modelContext: context)
        }
    }
}

@MainActor
private final class NetworkPathProbe {
    var path = AutoDownloadFixture.wiFi
    var isHeld = false
    private(set) var callCount = 0
    private(set) var returnCount = 0

    func current() async -> NetworkPathSnapshot {
        callCount += 1
        while isHeld {
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                // A cancelled pass can't sleep; yield instead of spinning.
                await Task.yield()
            }
        }
        returnCount += 1
        return path
    }
}
