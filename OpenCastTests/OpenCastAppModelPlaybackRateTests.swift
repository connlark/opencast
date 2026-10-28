import Foundation
import OpenCastCore
@testable import OpenCastPlayback
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("App model playback speed")
struct OpenCastAppModelPlaybackRateTests {
    private static let customShowID = "https://example.com/custom-speed.xml"
    private static let globalShowID = "https://example.com/global-speed.xml"
    private static let customEpisodeID = "custom-speed-episode"
    private static let globalEpisodeID = "global-speed-episode"

    @Test("A show with its own speed loads at that speed and the next show loads at the global speed")
    func loadResolvesTheShowSpeedThenRestoresTheGlobalSpeed() async throws {
        let fixture = try await makeFixture()
        #expect(fixture.appModel.setPlaybackRate(1.25, modelContext: fixture.context))

        try play(Self.customEpisodeID, fixture: fixture)

        #expect(fixture.appModel.playback.rate == 1.5)
        #expect(fixture.appModel.playbackSettings.globalPlaybackRate == 1.25)
        #expect(try storedGlobalRate(fixture.context) == "1.25")

        try play(Self.globalEpisodeID, fixture: fixture)

        #expect(fixture.appModel.playback.rate == 1.25)
        #expect(try storedGlobalRate(fixture.context) == "1.25")
    }

    @Test("A speed change while a show with its own speed plays saves that show's speed, not the global one")
    func speedChangeEditsTheShowSpeed() async throws {
        let fixture = try await makeFixture()
        try play(Self.customEpisodeID, fixture: fixture)

        #expect(fixture.appModel.setPlaybackRate(2, modelContext: fixture.context))

        #expect(fixture.appModel.playback.rate == 2)
        #expect(fixture.appModel.library.podcastPlaybackRateOverride(forPodcastID: Self.customShowID) == 2)
        #expect(try savedPlaybackRate(forFeedURL: Self.customShowID, fixture: fixture) == 2)
        #expect(fixture.appModel.playbackSettings.globalPlaybackRate == 1)
        #expect(try storedGlobalRate(fixture.context) == nil)
        #expect(fixture.appModel.playbackSettings.lastErrorMessage == nil)
    }

    @Test("A failed save of the show's speed rolls the player back and surfaces the error once")
    func failedShowSpeedSaveRollsBack() async throws {
        let saveSwitch = SyncedSaveSwitch()
        let fixture = try await makeFixture(librarySave: { context in
            if saveSwitch.failsSaves {
                throw SimulatedSyncedSaveFailure()
            }
            try context.save()
        })
        try play(Self.customEpisodeID, fixture: fixture)
        saveSwitch.failsSaves = true

        #expect(!fixture.appModel.setPlaybackRate(2, modelContext: fixture.context))

        #expect(fixture.appModel.playback.rate == 1.5)
        #expect(fixture.appModel.library.podcastPlaybackRateOverride(forPodcastID: Self.customShowID) == 1.5)
        #expect(
            fixture.appModel.playbackSettings.lastErrorMessage
                == "Unable to update this show's speed: Simulated synced save failure"
        )
        // The speed sheet shows the failure; the root Library alert must not
        // show it a second time.
        #expect(fixture.appModel.library.lastErrorMessage == nil)
        #expect(try storedGlobalRate(fixture.context) == nil)
    }

    @Test("Turning the show's speed off while it plays drops to the global speed at once")
    func clearingTheShowSpeedAppliesTheGlobalSpeedImmediately() async throws {
        let fixture = try await makeFixture()
        #expect(fixture.appModel.setPlaybackRate(1.25, modelContext: fixture.context))
        try play(Self.customEpisodeID, fixture: fixture)
        #expect(fixture.appModel.playback.rate == 1.5)

        #expect(fixture.appModel.setPodcastPlaybackRateOverride(nil, feedURL: Self.customShowID, modelContext: fixture.context))

        #expect(fixture.appModel.playback.rate == 1.25)
        #expect(fixture.appModel.library.podcastPlaybackRateOverride(forPodcastID: Self.customShowID) == nil)
        #expect(try savedPlaybackRate(forFeedURL: Self.customShowID, fixture: fixture) == 0)
        #expect(try storedGlobalRate(fixture.context) == "1.25")
    }

    @Test("Turning the show's speed on while it plays keeps the current speed and later changes edit the show")
    func settingTheShowSpeedToTheCurrentRateKeepsPlaybackAsItWas() async throws {
        let fixture = try await makeFixture()
        #expect(fixture.appModel.setPlaybackRate(1.25, modelContext: fixture.context))
        try play(Self.globalEpisodeID, fixture: fixture)
        #expect(fixture.appModel.playback.rate == 1.25)

        #expect(fixture.appModel.setPodcastPlaybackRateOverride(
            fixture.appModel.playback.rate,
            feedURL: Self.globalShowID,
            modelContext: fixture.context
        ))

        #expect(fixture.appModel.playback.rate == 1.25)
        #expect(fixture.appModel.library.podcastPlaybackRateOverride(forPodcastID: Self.globalShowID) == 1.25)
        #expect(try savedPlaybackRate(forFeedURL: Self.globalShowID, fixture: fixture) == 1.25)

        #expect(fixture.appModel.setPlaybackRate(1.75, modelContext: fixture.context))

        #expect(fixture.appModel.playback.rate == 1.75)
        #expect(fixture.appModel.library.podcastPlaybackRateOverride(forPodcastID: Self.globalShowID) == 1.75)
        #expect(fixture.appModel.playbackSettings.globalPlaybackRate == 1.25)
        #expect(try storedGlobalRate(fixture.context) == "1.25")
    }

    @Test("Saving the playing show's settings applies its speed at once; another show's leaves the player alone")
    func showSettingsSaveAppliesOnlyToThePlayingShow() async throws {
        let fixture = try await makeFixture()
        try play(Self.customEpisodeID, fixture: fixture)

        #expect(fixture.appModel.setPodcastPlaybackSettings(
            PodcastPlaybackSkipSettings(skipIntroSeconds: 30),
            rateOverride: 1.75,
            feedURL: Self.customShowID,
            modelContext: fixture.context
        ))
        #expect(fixture.appModel.playback.rate == 1.75)

        #expect(fixture.appModel.setPodcastPlaybackSettings(
            .disabled,
            rateOverride: 2,
            feedURL: Self.globalShowID,
            modelContext: fixture.context
        ))
        #expect(fixture.appModel.setPodcastPlaybackRateOverride(
            0.75,
            feedURL: Self.globalShowID,
            modelContext: fixture.context
        ))
        #expect(fixture.appModel.playback.rate == 1.75)
        #expect(fixture.appModel.library.podcastPlaybackRateOverride(forPodcastID: Self.globalShowID) == 0.75)

        #expect(fixture.appModel.setPodcastPlaybackSettings(
            PodcastPlaybackSkipSettings(skipIntroSeconds: 30),
            rateOverride: nil,
            feedURL: Self.customShowID,
            modelContext: fixture.context
        ))
        #expect(fixture.appModel.playback.rate == 1)
    }

    @Test("A rejected show speed leaves the player and the saved speed alone")
    func rejectedShowSpeedLeavesPlaybackAlone() async throws {
        let fixture = try await makeFixture()
        try play(Self.customEpisodeID, fixture: fixture)

        #expect(!fixture.appModel.setPodcastPlaybackRateOverride(4, feedURL: Self.customShowID, modelContext: fixture.context))

        #expect(fixture.appModel.playback.rate == 1.5)
        #expect(fixture.appModel.library.podcastPlaybackRateOverride(forPodcastID: Self.customShowID) == 1.5)
        #expect(fixture.appModel.library.lastErrorMessage == "Speed must be between 0.5x and 3x.")
    }

    @Test("The lock-screen rate command edits the show's speed while it has one and the global speed otherwise")
    func remoteRateCommandRoutesByShow() async throws {
        let fixture = try await makeFixture()
        try play(Self.customEpisodeID, fixture: fixture)

        fixture.appModel.playback.handleRemotePlaybackRateChange(2)

        #expect(fixture.appModel.playback.rate == 2)
        #expect(fixture.appModel.library.podcastPlaybackRateOverride(forPodcastID: Self.customShowID) == 2)
        #expect(try storedGlobalRate(fixture.context) == nil)

        try play(Self.globalEpisodeID, fixture: fixture)
        #expect(fixture.appModel.playback.rate == 1)

        fixture.appModel.playback.handleRemotePlaybackRateChange(1.75)

        #expect(fixture.appModel.playback.rate == 1.75)
        #expect(try storedGlobalRate(fixture.context) == "1.75")
        #expect(fixture.appModel.library.podcastPlaybackRateOverride(forPodcastID: Self.globalShowID) == nil)
        #expect(fixture.appModel.library.podcastPlaybackRateOverride(forPodcastID: Self.customShowID) == 2)
    }

    @Test("CarPlay's rate button cycles the show's speed while it has one")
    func cyclingTheRateEditsTheShowSpeed() async throws {
        let fixture = try await makeFixture()
        try play(Self.customEpisodeID, fixture: fixture)

        #expect(fixture.appModel.cyclePlaybackRate(modelContext: fixture.context))

        #expect(fixture.appModel.playback.rate == 1.75)
        #expect(fixture.appModel.library.podcastPlaybackRateOverride(forPodcastID: Self.customShowID) == 1.75)
        #expect(try storedGlobalRate(fixture.context) == nil)
    }

    @Test("Foreground activation applies the playing show's speed changed on another device")
    func foregroundRefreshAppliesARemoteShowSpeed() async throws {
        let fixture = try await makeFixture()
        try play(Self.customEpisodeID, fixture: fixture)
        let subscription = try #require(
            fixture.context.fetch(FetchDescriptor<SubscriptionRecord>()).first { $0.feedURL == Self.customShowID }
        )
        subscription.playbackRate = 2
        try fixture.context.save()
        #expect(fixture.appModel.playback.rate == 1.5)

        fixture.appModel.refreshCurrentPlaybackSettings(modelContext: fixture.context)

        #expect(fixture.appModel.playback.rate == 2)
    }

    @Test("Reloading and repairing imported records plays the show at its repaired speed")
    func reloadAndRepairAppliesTheRepairedShowSpeed() async throws {
        let fixture = try await makeFixture()
        try play(Self.customEpisodeID, fixture: fixture)
        let importContext = ModelContext(fixture.context.container)
        let importedSubscription = try #require(
            importContext.fetch(FetchDescriptor<SubscriptionRecord>()).first { $0.feedURL == Self.customShowID }
        )
        importedSubscription.playbackRate = 2
        // Sorts ahead of the original by title, so a read between the reload
        // and the repair would find this twin's speed.
        importContext.insert(SubscriptionRecord(
            feedURL: Self.customShowID,
            title: "A Custom Speed Show",
            playbackRate: 1.25
        ))
        try importContext.save()
        #expect(fixture.appModel.playback.rate == 1.5)

        #expect(await fixture.appModel.reloadPersistedDataAndRepairDuplicates(modelContext: fixture.context))

        #expect(fixture.appModel.playback.rate == 2)
        #expect(fixture.appModel.library.podcastPlaybackRateOverride(forPodcastID: Self.customShowID) == 2)
        #expect(try ModelContext(fixture.context.container)
            .fetch(FetchDescriptor<SubscriptionRecord>())
            .count { $0.feedURL == Self.customShowID } == 1)
        #expect(fixture.appModel.playbackSettings.globalPlaybackRate == 1)
        #expect(try storedGlobalRate(fixture.context) == nil)
    }

    @Test("Activation refetches the playing show and applies the speed another device saved, the global speed untouched")
    func activationRefetchAppliesAnImportedShowSpeed() async throws {
        let fixture = try await makeFixture()
        #expect(fixture.appModel.setPlaybackRate(1.25, modelContext: fixture.context))
        try play(Self.customEpisodeID, fixture: fixture)
        #expect(fixture.appModel.playback.rate == 1.5)
        let importContext = ModelContext(fixture.context.container)
        let importedSubscription = try #require(
            importContext.fetch(FetchDescriptor<SubscriptionRecord>()).first { $0.feedURL == Self.customShowID }
        )
        importedSubscription.playbackRate = 2
        try importContext.save()

        fixture.appModel.refreshCurrentPlaybackSettingsFromStore(modelContext: fixture.context)

        #expect(fixture.appModel.playback.rate == 2)
        #expect(fixture.appModel.library.podcastPlaybackRateOverride(forPodcastID: Self.customShowID) == 2)
        #expect(fixture.appModel.playbackSettings.globalPlaybackRate == 1.25)
        #expect(try storedGlobalRate(fixture.context) == "1.25")
    }

    private func makeFixture(
        librarySave: ((ModelContext) throws -> Void)? = nil
    ) async throws -> (appModel: OpenCastAppModel, context: ModelContext) {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        try await cache.upsertCache(
            from: feedSnapshot(feedURL: Self.customShowID, title: "Custom Speed Show", episodeID: Self.customEpisodeID),
            refreshedAt: .now
        )
        try await cache.upsertCache(
            from: feedSnapshot(feedURL: Self.globalShowID, title: "Global Speed Show", episodeID: Self.globalEpisodeID),
            refreshedAt: .now
        )
        context.insert(SubscriptionRecord(feedURL: Self.customShowID, title: "Custom Speed Show", playbackRate: 1.5))
        context.insert(SubscriptionRecord(feedURL: Self.globalShowID, title: "Global Speed Show"))
        try context.save()
        let appModel = OpenCastAppModel(
            library: librarySave.map { LibraryStore(localCache: cache, savePlaybackSkipSettingsModelContext: $0) },
            localLibraryCacheStore: cache,
            allowsAutomaticFeedRefresh: false
        )
        await appModel.ensureCoreStoresLoaded(modelContext: context)
        return (appModel, context)
    }

    private func feedSnapshot(feedURL: String, title: String, episodeID: String) throws -> FeedSnapshot {
        let podcast = Podcast(
            id: PodcastID(rawValue: feedURL),
            feedURL: try #require(URL(string: feedURL)),
            title: title
        )
        return FeedSnapshot(
            podcast: podcast,
            episodes: [
                Episode(
                    id: EpisodeID(rawValue: episodeID),
                    podcastID: podcast.id,
                    podcastTitle: title,
                    title: "Episode \(episodeID)",
                    duration: 60,
                    audioURL: URL(string: "https://example.com/\(episodeID).mp3"),
                    guid: episodeID
                )
            ]
        )
    }

    private func play(
        _ episodeID: String,
        fixture: (appModel: OpenCastAppModel, context: ModelContext)
    ) throws {
        let episode = try #require(fixture.appModel.episodeSnapshot(for: episodeID))
        try fixture.appModel.playEpisode(
            episode,
            at: nil,
            matchingSourceSHA256: "no-matching-download",
            presentsNowPlaying: false,
            autoplay: false,
            modelContext: fixture.context
        )
        #expect(fixture.appModel.playback.currentEpisode?.id.rawValue == episodeID)
    }

    private func storedGlobalRate(_ context: ModelContext) throws -> String? {
        try LocalPreferenceRecord.preference(
            forKey: PlaybackSettingsStore.playbackRatePreferenceKey,
            modelContext: context
        )?.value
    }

    private func savedPlaybackRate(
        forFeedURL feedURL: String,
        fixture: (appModel: OpenCastAppModel, context: ModelContext)
    ) throws -> Double? {
        try ModelContext(fixture.context.container)
            .fetch(FetchDescriptor<SubscriptionRecord>())
            .first { $0.feedURL == feedURL }?
            .playbackRate
    }
}

private final class SyncedSaveSwitch {
    var failsSaves = false
}

private struct SimulatedSyncedSaveFailure: LocalizedError {
    var errorDescription: String? { "Simulated synced save failure" }
}
