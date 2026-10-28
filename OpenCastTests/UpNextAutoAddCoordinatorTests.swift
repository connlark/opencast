import Foundation
import OpenCastCore
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Auto Add to Up Next")
struct UpNextAutoAddCoordinatorTests {
    private typealias Fixture = UpNextAutoAddFixture

    @Test("Turning a show on writes its position and a watermark at its newest release, and queues nothing")
    func enableSetsWatermarkAndQueuesNothing() async throws {
        let fixture = try await Fixture.make()
        try await fixture.publish(releaseDays: [1, 2, 3, 31])

        #expect(fixture.coordinator.setPosition(.bottom, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))

        #expect(fixture.library.podcastUpNextAutoAddPosition(forPodcastID: Fixture.topFeedURL) == .bottom)
        #expect(try fixture.storedAutoAddToUpNext(Fixture.topFeedURL) == 1)
        #expect(fixture.watermark() == Fixture.release(3))
        #expect(fixture.queuedIDs.isEmpty)

        fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.queuedIDs.isEmpty)
        #expect(fixture.watermark() == Fixture.release(3))
    }

    @Test("Moving a show between Top and Bottom keeps its watermark; turning it off deletes the row")
    func positionChangeKeepsWatermarkAndOffDeletesIt() async throws {
        let fixture = try await Fixture.make()
        try await fixture.publish(releaseDays: [1, 2, 3])
        #expect(fixture.coordinator.setPosition(.bottom, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))
        fixture.now = Fixture.release(40)

        #expect(fixture.coordinator.setPosition(.top, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))
        #expect(fixture.library.podcastUpNextAutoAddPosition(forPodcastID: Fixture.topFeedURL) == .top)
        #expect(fixture.watermark() == Fixture.release(3))

        #expect(fixture.coordinator.setPosition(nil, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))
        #expect(fixture.library.podcastUpNextAutoAddPosition(forPodcastID: Fixture.topFeedURL) == nil)
        #expect(try fixture.storedAutoAddToUpNext(Fixture.topFeedURL) == 0)
        #expect(fixture.watermark() == nil)
        #expect(try fixture.storedWatermarkRows(Fixture.topFeedURL).isEmpty)
        #expect(fixture.coordinator.setPosition(nil, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))
    }

    @Test("A failed synced save turns nothing on and writes no watermark")
    func failedSyncedSaveLeavesNoWatermark() async throws {
        let fixture = try await Fixture.make()
        try await fixture.publish(releaseDays: [1, 2, 3])
        fixture.librarySaves.fails = true

        #expect(!fixture.coordinator.setPosition(.top, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))

        #expect(fixture.library.podcastUpNextAutoAddPosition(forPodcastID: Fixture.topFeedURL) == nil)
        #expect(fixture.library.lastErrorMessage?.hasPrefix("Unable to update Add to Up Next: ") == true)
        #expect(fixture.watermark() == nil)
        #expect(try fixture.storedWatermarkRows(Fixture.topFeedURL).isEmpty)
    }

    @Test("Turning a show on again after a failed watermark write retries the write until it succeeds")
    func turnOnRetriesAFailedWatermarkWrite() async throws {
        let fixture = try await Fixture.make()
        try await fixture.publish(releaseDays: [1, 2, 3])
        fixture.settingsSaves.fails = true

        #expect(!fixture.coordinator.setPosition(.top, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))
        #expect(!fixture.coordinator.setPosition(.top, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))

        #expect(fixture.library.podcastUpNextAutoAddPosition(forPodcastID: Fixture.topFeedURL) == nil)
        #expect(fixture.settings.lastErrorMessage?.hasPrefix("Unable to record new episodes for Up Next: ") == true)
        #expect(fixture.watermark() == nil)
        #expect(try fixture.storedWatermarkRows(Fixture.topFeedURL).isEmpty)

        fixture.settingsSaves.fails = false
        #expect(fixture.coordinator.setPosition(.top, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))

        #expect(fixture.watermark() == Fixture.release(3))
        #expect(try fixture.storedWatermarkRows(Fixture.topFeedURL) == [UpNextAutoAddSettingsStore.encodeWatermark(Fixture.release(3))])
        #expect(fixture.queuedIDs.isEmpty)
    }

    @Test("Turning a show off again after a failed removal retries it, and the row stays until it succeeds")
    func turnOffRetriesAFailedWatermarkRemoval() async throws {
        let fixture = try await Fixture.make()
        try await fixture.publish(releaseDays: [1, 2, 3])
        #expect(fixture.coordinator.setPosition(.bottom, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))
        fixture.settingsSaves.fails = true

        #expect(!fixture.coordinator.setPosition(nil, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))
        #expect(!fixture.coordinator.setPosition(nil, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))

        #expect(fixture.library.podcastUpNextAutoAddPosition(forPodcastID: Fixture.topFeedURL) == nil)
        #expect(fixture.settings.lastErrorMessage?.hasPrefix("Unable to remove this show's Up Next settings: ") == true)
        #expect(fixture.watermark() == Fixture.release(3))
        #expect(try fixture.storedWatermarkRows(Fixture.topFeedURL).count == 1)

        fixture.settingsSaves.fails = false
        #expect(fixture.coordinator.setPosition(nil, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))

        #expect(fixture.watermark() == nil)
        #expect(try fixture.storedWatermarkRows(Fixture.topFeedURL).isEmpty)
    }

    @Test("Turning a show on over a watermark left from an earlier time it was on starts again at its newest release")
    func localEnableReplacesAStaleWatermark() async throws {
        let fixture = try await Fixture.make()
        try await fixture.publish(releaseDays: [1])
        #expect(fixture.coordinator.setPosition(.bottom, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))
        // Another device turns the show off, and no pass of this device
        // deletes the row before the show is turned on here again.
        #expect(fixture.library.setPodcastUpNextAutoAddPosition(nil, feedURL: Fixture.topFeedURL, modelContext: fixture.context))
        try await fixture.publish(releaseDays: [1, 2, 3])
        #expect(fixture.watermark() == Fixture.release(1))

        #expect(fixture.coordinator.setPosition(.top, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))

        #expect(fixture.watermark() == Fixture.release(3))
        #expect(try fixture.storedWatermarkRows(Fixture.topFeedURL) == [UpNextAutoAddSettingsStore.encodeWatermark(Fixture.release(3))])

        fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.queuedIDs.isEmpty)
        #expect(fixture.watermark() == Fixture.release(3))
    }

    @Test("Turning a show on after a failed Off starts at its newest release, not at the row the failed removal kept")
    func reEnableAfterAFailedRemovalStartsFresh() async throws {
        let fixture = try await Fixture.make()
        try await fixture.publish(releaseDays: [1])
        #expect(fixture.coordinator.setPosition(.bottom, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))
        fixture.settingsSaves.fails = true
        #expect(!fixture.coordinator.setPosition(nil, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))
        #expect(fixture.library.podcastUpNextAutoAddPosition(forPodcastID: Fixture.topFeedURL) == nil)
        #expect(fixture.watermark() == Fixture.release(1))
        try await fixture.publish(releaseDays: [1, 2, 3])
        fixture.settingsSaves.fails = false

        #expect(fixture.coordinator.setPosition(.bottom, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))

        #expect(fixture.watermark() == Fixture.release(3))
        #expect(try fixture.storedWatermarkRows(Fixture.topFeedURL) == [UpNextAutoAddSettingsStore.encodeWatermark(Fixture.release(3))])

        fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.queuedIDs.isEmpty)
        #expect(fixture.watermark() == Fixture.release(3))
    }

    @Test("A show with no released episode starts its watermark now")
    func enableWithNoReleasedEpisodeStartsNow() async throws {
        let fixture = try await Fixture.make()
        try await fixture.publish(releaseDays: [31])

        #expect(fixture.coordinator.setPosition(.bottom, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))

        #expect(fixture.watermark() == Fixture.release(30))

        fixture.now = Fixture.release(32)
        fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.queuedIDs == [fixture.id(0)])
        #expect(fixture.watermark() == Fixture.release(31))
    }

    @Test("A show turned on by sync starts at its newest release and queues nothing until the next one")
    func syncArrivalHealsWithoutQueuing() async throws {
        let fixture = try await Fixture.make()
        try await fixture.publish(releaseDays: [1, 2, 3])
        #expect(fixture.library.setPodcastUpNextAutoAddPosition(.top, feedURL: Fixture.topFeedURL, modelContext: fixture.context))

        fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.watermark() == Fixture.release(3))
        #expect(fixture.queuedIDs.isEmpty)

        try await fixture.publish(releaseDays: [1, 2, 3, 4])
        fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.queuedIDs == [fixture.id(3)])
        #expect(fixture.watermark() == Fixture.release(4))
    }

    @Test("New releases queue at the bottom in release order")
    func newReleasesQueueAtTheBottomInReleaseOrder() async throws {
        let fixture = try await Fixture.make()
        try await fixture.publish(releaseDays: [1, 2, 3])
        #expect(fixture.coordinator.setPosition(.bottom, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))
        fixture.queueHandRows(1)

        try await fixture.publish(releaseDays: [1, 2, 3, 4])
        fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.queuedIDs == ["hand-0", fixture.id(3)])
        #expect(fixture.watermark() == Fixture.release(4))

        try await fixture.publish(releaseDays: [1, 2, 3, 4, 5, 6])
        fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.queuedIDs == ["hand-0", fixture.id(3), fixture.id(4), fixture.id(5)])
        #expect(fixture.watermark() == Fixture.release(6))
        #expect(fixture.upNextQueue.items.allSatisfy { $0.sourcePlaylistID == nil })
    }

    @Test("New releases queue at the top, newest first")
    func newReleasesQueueAtTheTopNewestFirst() async throws {
        let fixture = try await Fixture.make()
        try await fixture.publish(releaseDays: [1, 2, 3])
        #expect(fixture.coordinator.setPosition(.top, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))
        fixture.queueHandRows(1)

        try await fixture.publish(releaseDays: [1, 2, 3, 4])
        fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.queuedIDs == [fixture.id(3), "hand-0"])

        try await fixture.publish(releaseDays: [1, 2, 3, 4, 5, 6])
        fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.queuedIDs == [fixture.id(5), fixture.id(4), fixture.id(3), "hand-0"])
        #expect(fixture.watermark() == Fixture.release(6))
    }

    @Test("Played, already queued, playing and audio-less releases are skipped, and the watermark still moves past them")
    func ineligibleReleasesAreSkippedForGood() async throws {
        let fixture = try await Fixture.make()
        try await fixture.publish(releaseDays: [1])
        #expect(fixture.coordinator.setPosition(.bottom, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))
        try await fixture.publish(releaseDays: [1, 2, 3, 4, 5, 6], audioLessIndices: [4])
        try fixture.markPlayed(1)
        let queuedByHand = try fixture.episode(2)
        #expect(fixture.upNextQueue.enqueueLast(queuedByHand, modelContext: fixture.context))
        fixture.currentEpisodeID = fixture.id(3)

        fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.queuedIDs == [fixture.id(2), fixture.id(5)])
        #expect(fixture.watermark() == Fixture.release(6))

        // Skipped stays skipped once the episode would qualify.
        fixture.currentEpisodeID = nil
        #expect(fixture.upNextQueue.clear(modelContext: fixture.context))
        fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.queuedIDs.isEmpty)
    }

    @Test("Stop Adding at the limit leaves the rest out for good and still moves every watermark")
    func stopAddingAtTheLimit() async throws {
        let fixture = try await Fixture.make(subscribedFeedURLs: [Fixture.topFeedURL, Fixture.bottomFeedURL])
        try await fixture.publish(releaseDays: [1])
        try await fixture.publish(Fixture.bottomFeedURL, releaseDays: [1])
        #expect(fixture.settings.setLimit(.ten, modelContext: fixture.context))
        #expect(fixture.coordinator.setPosition(.top, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))
        #expect(fixture.coordinator.setPosition(.bottom, forPodcastID: Fixture.bottomFeedURL, modelContext: fixture.context))
        fixture.queueHandRows(8)
        try await fixture.publish(releaseDays: [1, 2])
        try await fixture.publish(Fixture.bottomFeedURL, releaseDays: [1, 2, 3])

        fixture.coordinator.runPass(modelContext: fixture.context)

        // The Top show runs first (sorted IDs): 8 + 1 = 9; the Bottom show fills
        // the tenth row with its older release and drops the newer one.
        #expect(fixture.queuedIDs == [fixture.id(1)] + fixture.handIDs(8) + [fixture.id(1, in: Fixture.bottomFeedURL)])
        #expect(fixture.watermark() == Fixture.release(2))
        #expect(fixture.watermark(Fixture.bottomFeedURL) == Fixture.release(3))

        try await fixture.publish(releaseDays: [1, 2, 4])
        fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.queuedIDs.count == 10)
        #expect(!fixture.queuedIDs.contains(fixture.id(2)))
        #expect(fixture.watermark() == Fixture.release(4))

        #expect(fixture.upNextQueue.clear(modelContext: fixture.context))
        fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.queuedIDs.isEmpty)
    }

    @Test("Only Add to Top at the limit replaces the last rows for a Top show and leaves a Bottom show out")
    func onlyAddToTopAtTheLimit() async throws {
        let fixture = try await Fixture.make(subscribedFeedURLs: [Fixture.topFeedURL, Fixture.bottomFeedURL])
        try await fixture.publish(releaseDays: [1])
        try await fixture.publish(Fixture.bottomFeedURL, releaseDays: [1])
        #expect(fixture.settings.setLimit(.ten, modelContext: fixture.context))
        #expect(fixture.settings.setLimitReachedAction(.addToTopOnly, modelContext: fixture.context))
        #expect(fixture.coordinator.setPosition(.top, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))
        #expect(fixture.coordinator.setPosition(.bottom, forPodcastID: Fixture.bottomFeedURL, modelContext: fixture.context))
        fixture.queueHandRows(10)
        try await fixture.publish(releaseDays: [1, 2, 3])
        try await fixture.publish(Fixture.bottomFeedURL, releaseDays: [1, 2])

        fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.queuedIDs == [fixture.id(2), fixture.id(1)] + fixture.handIDs(8))
        #expect(fixture.watermark() == Fixture.release(3))
        #expect(fixture.watermark(Fixture.bottomFeedURL) == Fixture.release(2))
    }

    @Test("Only Add to Top keeps the newest releases when one pass's batch alone passes the limit")
    func onlyAddToTopEvictsWithinItsOwnBatch() async throws {
        let fixture = try await Fixture.make()
        try await fixture.publish(releaseDays: [1])
        #expect(fixture.settings.setLimit(.ten, modelContext: fixture.context))
        #expect(fixture.settings.setLimitReachedAction(.addToTopOnly, modelContext: fixture.context))
        #expect(fixture.coordinator.setPosition(.top, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))
        try await fixture.publish(releaseDays: Array(1...13))

        fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.queuedIDs == (3...12).reversed().map { fixture.id($0) })
        #expect(fixture.watermark() == Fixture.release(13))
    }

    @Test("A show turned off or unsubscribed is ignored, and the pass deletes the unsubscribed show's watermark row")
    func offAndUnsubscribedShowsAreIgnored() async throws {
        let fixture = try await Fixture.make(subscribedFeedURLs: [Fixture.topFeedURL, Fixture.bottomFeedURL])
        try await fixture.publish(releaseDays: [1])
        try await fixture.publish(Fixture.bottomFeedURL, releaseDays: [1])
        #expect(fixture.coordinator.setPosition(.top, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))
        #expect(fixture.coordinator.setPosition(.bottom, forPodcastID: Fixture.bottomFeedURL, modelContext: fixture.context))
        #expect(fixture.coordinator.setPosition(nil, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))
        await fixture.library.unsubscribe(feedURL: Fixture.bottomFeedURL, modelContext: fixture.context)
        #expect(fixture.library.upNextAutoAddPodcastIDs.isEmpty)
        #expect(fixture.watermark(Fixture.bottomFeedURL) == Fixture.release(1))
        try await fixture.publish(releaseDays: [1, 2])

        fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.queuedIDs.isEmpty)
        #expect(fixture.watermark() == nil)
        #expect(fixture.watermark(Fixture.bottomFeedURL) == nil)
        #expect(try fixture.storedWatermarkRows(Fixture.bottomFeedURL).isEmpty)
    }

    @Test("A pass deletes the watermark of a show turned off by sync and keeps the ones still on; back on, it heals at the newest release")
    func passDeletesWatermarksOfShowsTurnedOffBySync() async throws {
        let fixture = try await Fixture.make(subscribedFeedURLs: [Fixture.topFeedURL, Fixture.bottomFeedURL])
        try await fixture.publish(releaseDays: [1])
        try await fixture.publish(Fixture.bottomFeedURL, releaseDays: [1])
        #expect(fixture.coordinator.setPosition(.top, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))
        #expect(fixture.coordinator.setPosition(.bottom, forPodcastID: Fixture.bottomFeedURL, modelContext: fixture.context))
        // Another device turns the Top show off; this device's row outlives it.
        #expect(fixture.library.setPodcastUpNextAutoAddPosition(nil, feedURL: Fixture.topFeedURL, modelContext: fixture.context))
        #expect(fixture.watermark() == Fixture.release(1))
        try await fixture.publish(releaseDays: [1, 2, 3])

        fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.watermark() == nil)
        #expect(try fixture.storedWatermarkRows(Fixture.topFeedURL).isEmpty)
        #expect(fixture.watermark(Fixture.bottomFeedURL) == Fixture.release(1))
        #expect(try fixture.storedWatermarkRows(Fixture.bottomFeedURL) == [UpNextAutoAddSettingsStore.encodeWatermark(Fixture.release(1))])
        #expect(fixture.queuedIDs.isEmpty)

        // Back on from another device: the releases while it was off stay out.
        #expect(fixture.library.setPodcastUpNextAutoAddPosition(.top, feedURL: Fixture.topFeedURL, modelContext: fixture.context))
        fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.watermark() == Fixture.release(3))
        #expect(fixture.queuedIDs.isEmpty)
    }

    @Test("A watermark row deleted while the show stays on heals at the newest release and queues nothing")
    func deletedWatermarkRowHealsAtTheNewestRelease() async throws {
        let fixture = try await Fixture.make()
        try await fixture.publish(releaseDays: [1])
        #expect(fixture.coordinator.setPosition(.bottom, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))
        try await fixture.publish(releaseDays: [1, 2, 3])
        try fixture.deleteStoredWatermarkRows(Fixture.topFeedURL)
        fixture.settings.load(modelContext: fixture.context)
        #expect(fixture.watermark() == nil)

        fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.watermark() == Fixture.release(3))
        #expect(try fixture.storedWatermarkRows(Fixture.topFeedURL) == [UpNextAutoAddSettingsStore.encodeWatermark(Fixture.release(3))])
        #expect(fixture.queuedIDs.isEmpty)
    }

    @Test("Only Add to Top puts back on top a queued release that an older release evicted")
    func onlyAddToTopRequeuesAReleaseItEvicted() async throws {
        let fixture = try await Fixture.make()
        try await fixture.publish(releaseDays: [1])
        #expect(fixture.settings.setLimit(.ten, modelContext: fixture.context))
        #expect(fixture.settings.setLimitReachedAction(.addToTopOnly, modelContext: fixture.context))
        #expect(fixture.coordinator.setPosition(.top, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))
        try await fixture.publish(releaseDays: [1, 2, 3])
        fixture.queueHandRows(9)
        #expect(fixture.upNextQueue.enqueueLast(try fixture.episode(2), modelContext: fixture.context))
        #expect(fixture.queuedIDs == fixture.handIDs(9) + [fixture.id(2)])

        fixture.coordinator.runPass(modelContext: fixture.context)

        // The older release evicts the queued newer one, which then evicts
        // the last hand-queued row and goes back on top.
        #expect(fixture.queuedIDs == [fixture.id(2), fixture.id(1)] + fixture.handIDs(8))
        #expect(try fixture.storedQueueIDs() == [fixture.id(2), fixture.id(1)] + fixture.handIDs(8))
        #expect(fixture.watermark() == Fixture.release(3))
    }

    @Test(
        "Where nothing is evicted, a queued release stays where it is and the full queue is left alone",
        arguments: [
            (UpNextAutoAddPosition.bottom, UpNextAutoAddLimitReachedAction.stopAdding),
            (UpNextAutoAddPosition.top, UpNextAutoAddLimitReachedAction.stopAdding),
            (UpNextAutoAddPosition.bottom, UpNextAutoAddLimitReachedAction.addToTopOnly),
        ]
    )
    func queuedReleaseStaysWhereNothingIsEvicted(
        position: UpNextAutoAddPosition,
        limitReachedAction: UpNextAutoAddLimitReachedAction
    ) async throws {
        let fixture = try await Fixture.make()
        try await fixture.publish(releaseDays: [1])
        #expect(fixture.settings.setLimit(.ten, modelContext: fixture.context))
        #expect(fixture.settings.setLimitReachedAction(limitReachedAction, modelContext: fixture.context))
        #expect(fixture.coordinator.setPosition(position, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))
        try await fixture.publish(releaseDays: [1, 2, 3])
        fixture.queueHandRows(9)
        #expect(fixture.upNextQueue.enqueueLast(try fixture.episode(2), modelContext: fixture.context))

        fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.queuedIDs == fixture.handIDs(9) + [fixture.id(2)])
        #expect(try fixture.storedQueueIDs() == fixture.handIDs(9) + [fixture.id(2)])
        #expect(fixture.watermark() == Fixture.release(3))
    }

    @Test("A failed queue save keeps the watermark, so the next pass queues the same releases")
    func failedQueueSaveKeepsWatermark() async throws {
        let fixture = try await Fixture.make()
        try await fixture.publish(releaseDays: [1])
        #expect(fixture.coordinator.setPosition(.bottom, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))
        try await fixture.publish(releaseDays: [1, 2, 3])
        fixture.queueSaves.fails = true

        let failure = fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.queuedIDs.isEmpty)
        #expect(fixture.watermark() == Fixture.release(1))
        #expect(failure == "Unable to add episodes to Up Next: Simulated save failure")
        #expect(fixture.upNextQueue.lastErrorMessage == nil)

        fixture.queueSaves.fails = false
        fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.queuedIDs == [fixture.id(1), fixture.id(2)])
        #expect(fixture.watermark() == Fixture.release(3))
    }

    @Test("A failed eviction keeps the watermark and queues nothing")
    func failedEvictionKeepsWatermark() async throws {
        let fixture = try await Fixture.make()
        try await fixture.publish(releaseDays: [1])
        #expect(fixture.settings.setLimit(.ten, modelContext: fixture.context))
        #expect(fixture.settings.setLimitReachedAction(.addToTopOnly, modelContext: fixture.context))
        #expect(fixture.coordinator.setPosition(.top, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))
        fixture.queueHandRows(10)
        try await fixture.publish(releaseDays: [1, 2])
        fixture.queueSaves.fails = true

        let failure = fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(failure == "Unable to add the episode to Up Next: Simulated save failure")
        #expect(fixture.queuedIDs == fixture.handIDs(10))
        #expect(try fixture.storedQueueIDs() == fixture.handIDs(10))
        #expect(fixture.watermark() == Fixture.release(1))
    }

    @Test("Only Add to Top removes the last row and inserts the new episode in one queue save")
    func onlyAddToTopEvictsAndInsertsInOneSave() async throws {
        let fixture = try await Fixture.make()
        try await fixture.publish(releaseDays: [1])
        #expect(fixture.settings.setLimit(.ten, modelContext: fixture.context))
        #expect(fixture.settings.setLimitReachedAction(.addToTopOnly, modelContext: fixture.context))
        #expect(fixture.coordinator.setPosition(.top, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))
        fixture.queueHandRows(10)
        try await fixture.publish(releaseDays: [1, 2])
        fixture.queueSaves.savesBeforeFailing = 1

        fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.queuedIDs == [fixture.id(1)] + fixture.handIDs(9))
        #expect(try fixture.storedQueueIDs() == [fixture.id(1)] + fixture.handIDs(9))
        #expect(fixture.watermark() == Fixture.release(2))
    }

    @Test("A pass returns the first failed save's message, and nil once every save succeeds")
    func passReturnsTheFirstFailure() async throws {
        let fixture = try await Fixture.make(subscribedFeedURLs: [Fixture.topFeedURL, Fixture.bottomFeedURL])
        try await fixture.publish(releaseDays: [1])
        try await fixture.publish(Fixture.bottomFeedURL, releaseDays: [1])
        #expect(fixture.coordinator.setPosition(.top, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))
        #expect(fixture.coordinator.setPosition(.bottom, forPodcastID: Fixture.bottomFeedURL, modelContext: fixture.context))
        try await fixture.publish(releaseDays: [1, 2, 3])
        try await fixture.publish(Fixture.bottomFeedURL, releaseDays: [1, 2])
        fixture.queueSaves.fails = true

        // The Top show runs first (sorted IDs) with two releases, the Bottom
        // show second with one, so the messages differ.
        #expect(fixture.coordinator.runPass(modelContext: fixture.context) == "Unable to add episodes to Up Next: Simulated save failure")
        #expect(fixture.upNextQueue.lastErrorMessage == nil)

        fixture.queueSaves.fails = false

        #expect(fixture.coordinator.runPass(modelContext: fixture.context) == nil)
        #expect(fixture.queuedIDs == [fixture.id(2), fixture.id(1), fixture.id(1, in: Fixture.bottomFeedURL)])
    }

    @Test("Passes are ignored while no scene is active")
    func passesWaitForAnActiveScene() async throws {
        let fixture = try await Fixture.make()
        try await fixture.publish(releaseDays: [1])
        #expect(fixture.coordinator.setPosition(.bottom, forPodcastID: Fixture.topFeedURL, modelContext: fixture.context))
        try await fixture.publish(releaseDays: [1, 2])
        let windowA = UUID()
        let windowB = UUID()
        #expect(fixture.coordinator.isForeground)

        fixture.coordinator.setScene(windowA, isActive: false)
        #expect(!fixture.coordinator.isForeground)
        fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.queuedIDs.isEmpty)
        #expect(fixture.watermark() == Fixture.release(1))

        fixture.coordinator.setScene(windowB, isActive: true)
        #expect(fixture.coordinator.isForeground)
        fixture.coordinator.removeScene(windowB)
        #expect(!fixture.coordinator.isForeground)
        fixture.coordinator.runPass(modelContext: fixture.context)
        #expect(fixture.queuedIDs.isEmpty)

        fixture.coordinator.setScene(windowA, isActive: true)
        fixture.coordinator.runPass(modelContext: fixture.context)

        #expect(fixture.queuedIDs == [fixture.id(1)])
        #expect(fixture.watermark() == Fixture.release(2))
    }

    @Test("The show sheet's save writes the watermark when it turns a show on and deletes it when it turns it off")
    func playbackSettingsSaveReconcilesWatermark() async throws {
        let feedURL = Fixture.topFeedURL
        let (appModel, context) = try await Self.sheetAppModel()

        #expect(appModel.setPodcastPlaybackSettings(
            PodcastPlaybackSkipSettings(skipIntroSeconds: 30),
            rateOverride: nil,
            upNextAutoAdd: nil,
            feedURL: feedURL,
            modelContext: context
        ) == nil)
        #expect(appModel.upNextAutoAddSettings.watermark(forPodcastID: feedURL) == nil)

        #expect(appModel.setPodcastPlaybackSettings(
            PodcastPlaybackSkipSettings(skipIntroSeconds: 30),
            rateOverride: nil,
            upNextAutoAdd: .top,
            feedURL: feedURL,
            modelContext: context
        ) == nil)
        #expect(appModel.library.podcastUpNextAutoAddPosition(forPodcastID: feedURL) == .top)
        #expect(appModel.upNextAutoAddSettings.watermark(forPodcastID: feedURL) == Fixture.release(3))
        #expect(appModel.upNextQueue.items.isEmpty)

        #expect(appModel.setPodcastPlaybackSettings(
            PodcastPlaybackSkipSettings(skipIntroSeconds: 30),
            rateOverride: 1.5,
            upNextAutoAdd: .bottom,
            feedURL: feedURL,
            modelContext: context
        ) == nil)
        #expect(appModel.upNextAutoAddSettings.watermark(forPodcastID: feedURL) == Fixture.release(3))

        #expect(appModel.setPodcastPlaybackSettings(
            PodcastPlaybackSkipSettings(skipIntroSeconds: 30),
            rateOverride: 1.5,
            upNextAutoAdd: nil,
            feedURL: feedURL,
            modelContext: context
        ) == nil)
        #expect(appModel.library.podcastUpNextAutoAddPosition(forPodcastID: feedURL) == nil)
        #expect(appModel.upNextAutoAddSettings.watermark(forPodcastID: feedURL) == nil)
        #expect(appModel.upNextQueue.items.isEmpty)
    }

    @Test("The show sheet's save retries a failed watermark write or removal on every save until it succeeds")
    func playbackSettingsSaveRetriesFailedWatermarkWrites() async throws {
        let feedURL = Fixture.topFeedURL
        let settingsSaves = SaveSwitch()
        let (appModel, context) = try await Self.sheetAppModel(
            settings: UpNextAutoAddSettingsStore(save: settingsSaves.save)
        )
        func save(_ position: UpNextAutoAddPosition?) -> Bool {
            appModel.setPodcastPlaybackSettings(
                PodcastPlaybackSkipSettings(skipIntroSeconds: 30),
                rateOverride: nil,
                upNextAutoAdd: position,
                feedURL: feedURL,
                modelContext: context
            ) == nil
        }
        settingsSaves.fails = true

        #expect(!save(.bottom))
        #expect(!save(.bottom))

        #expect(appModel.library.podcastUpNextAutoAddPosition(forPodcastID: feedURL) == nil)
        #expect(appModel.upNextAutoAddSettings.lastErrorMessage?.hasPrefix("Unable to record new episodes for Up Next: ") == true)
        #expect(appModel.upNextAutoAddSettings.watermark(forPodcastID: feedURL) == nil)

        settingsSaves.fails = false
        #expect(save(.bottom))

        #expect(appModel.upNextAutoAddSettings.watermark(forPodcastID: feedURL) == Fixture.release(3))
        #expect(try Fixture.storedWatermarkRows(feedURL, in: context.container).count == 1)

        settingsSaves.fails = true

        #expect(!save(nil))
        #expect(!save(nil))

        #expect(appModel.library.podcastUpNextAutoAddPosition(forPodcastID: feedURL) == nil)
        #expect(appModel.upNextAutoAddSettings.lastErrorMessage?.hasPrefix("Unable to remove this show's Up Next settings: ") == true)
        #expect(appModel.upNextAutoAddSettings.watermark(forPodcastID: feedURL) == Fixture.release(3))
        #expect(try Fixture.storedWatermarkRows(feedURL, in: context.container).count == 1)

        settingsSaves.fails = false
        #expect(save(nil))

        #expect(appModel.upNextAutoAddSettings.watermark(forPodcastID: feedURL) == nil)
        #expect(try Fixture.storedWatermarkRows(feedURL, in: context.container).isEmpty)
        #expect(appModel.upNextQueue.items.isEmpty)
    }

    @Test("The show sheet's save turning a show on over a watermark left from an earlier time it was on starts again at its newest release")
    func playbackSettingsSaveReplacesAStaleWatermark() async throws {
        let feedURL = Fixture.topFeedURL
        // Another device turned the show off before this launch, and no pass
        // has deleted this device's row yet.
        let (appModel, context) = try await Self.sheetAppModel(storedWatermark: Fixture.release(1))
        #expect(appModel.upNextAutoAddSettings.watermark(forPodcastID: feedURL) == Fixture.release(1))

        #expect(appModel.setPodcastPlaybackSettings(
            PodcastPlaybackSkipSettings(skipIntroSeconds: 30),
            rateOverride: nil,
            upNextAutoAdd: .bottom,
            feedURL: feedURL,
            modelContext: context
        ) == nil)

        #expect(appModel.upNextAutoAddSettings.watermark(forPodcastID: feedURL) == Fixture.release(3))
        #expect(
            try Fixture.storedWatermarkRows(feedURL, in: context.container)
                == [UpNextAutoAddSettingsStore.encodeWatermark(Fixture.release(3))]
        )

        appModel.restorePlaybackSurfaceIfNeeded(modelContext: context)
        appModel.runUpNextAutoAddPass(modelContext: context)

        #expect(appModel.upNextQueue.items.isEmpty)
        #expect(appModel.upNextAutoAddSettings.watermark(forPodcastID: feedURL) == Fixture.release(3))
    }

    @Test("The show sheet turning a show on after a failed Off starts at its newest release, not at the row the failed removal kept")
    func playbackSettingsSaveReEnableAfterAFailedRemovalStartsFresh() async throws {
        let feedURL = Fixture.topFeedURL
        let settingsSaves = SaveSwitch()
        // On at Bottom since day 1; days 2 and 3 came out after this
        // device's last pass.
        let (appModel, context) = try await Self.sheetAppModel(
            settings: UpNextAutoAddSettingsStore(save: settingsSaves.save),
            position: .bottom,
            storedWatermark: Fixture.release(1)
        )
        func save(_ position: UpNextAutoAddPosition?) -> Bool {
            appModel.setPodcastPlaybackSettings(
                PodcastPlaybackSkipSettings(skipIntroSeconds: 30),
                rateOverride: nil,
                upNextAutoAdd: position,
                feedURL: feedURL,
                modelContext: context
            ) == nil
        }
        settingsSaves.fails = true
        #expect(!save(nil))
        #expect(appModel.library.podcastUpNextAutoAddPosition(forPodcastID: feedURL) == nil)
        #expect(appModel.upNextAutoAddSettings.watermark(forPodcastID: feedURL) == Fixture.release(1))
        settingsSaves.fails = false

        #expect(save(.bottom))

        #expect(appModel.upNextAutoAddSettings.watermark(forPodcastID: feedURL) == Fixture.release(3))
        #expect(
            try Fixture.storedWatermarkRows(feedURL, in: context.container)
                == [UpNextAutoAddSettingsStore.encodeWatermark(Fixture.release(3))]
        )

        appModel.restorePlaybackSurfaceIfNeeded(modelContext: context)
        appModel.runUpNextAutoAddPass(modelContext: context)

        #expect(appModel.upNextQueue.items.isEmpty)
    }

    @Test(
        "When the fresh watermark cannot be written, turning a show on fails before the synced save and the show stays off",
        arguments: AutoAddEntryPoint.allCases
    )
    func failedFreshWriteLeavesTheShowOff(entryPoint: AutoAddEntryPoint) async throws {
        let feedURL = Fixture.topFeedURL
        let settingsSaves = SaveSwitch()
        // Turned off by another device; this device's row outlives it.
        let (appModel, context) = try await Self.sheetAppModel(
            settings: UpNextAutoAddSettingsStore(save: settingsSaves.save),
            storedWatermark: Fixture.release(1)
        )
        settingsSaves.fails = true

        #expect(!entryPoint.set(.bottom, appModel: appModel, context: context))

        #expect(appModel.library.podcastUpNextAutoAddPosition(forPodcastID: feedURL) == nil)
        let subscription = try Self.storedSubscription(in: context.container)
        #expect(subscription.autoAddToUpNext == 0)
        #expect(subscription.skipIntroSeconds == 0)
        #expect(appModel.library.lastErrorMessage == nil)
        #expect(appModel.upNextAutoAddSettings.lastErrorMessage == "Unable to record new episodes for Up Next: Simulated save failure")
        #expect(appModel.upNextAutoAddSettings.watermark(forPodcastID: feedURL) == Fixture.release(1))
        #expect(
            try Fixture.storedWatermarkRows(feedURL, in: context.container)
                == [UpNextAutoAddSettingsStore.encodeWatermark(Fixture.release(1))]
        )

        settingsSaves.fails = false
        appModel.restorePlaybackSurfaceIfNeeded(modelContext: context)
        appModel.runUpNextAutoAddPass(modelContext: context)

        #expect(appModel.upNextQueue.items.isEmpty)
        #expect(appModel.upNextAutoAddSettings.watermark(forPodcastID: feedURL) == nil)
        #expect(try Fixture.storedWatermarkRows(feedURL, in: context.container).isEmpty)
    }

    @Test(
        "After a failed fresh write, turning the show on again writes its newest release and only then turns it on",
        arguments: AutoAddEntryPoint.allCases
    )
    func retryAfterAFailedFreshWriteTurnsTheShowOn(entryPoint: AutoAddEntryPoint) async throws {
        let feedURL = Fixture.topFeedURL
        let settingsSaves = SaveSwitch()
        let (appModel, context) = try await Self.sheetAppModel(
            settings: UpNextAutoAddSettingsStore(save: settingsSaves.save),
            storedWatermark: Fixture.release(1)
        )
        settingsSaves.failuresRemaining = 1

        #expect(!entryPoint.set(.bottom, appModel: appModel, context: context))

        #expect(appModel.library.podcastUpNextAutoAddPosition(forPodcastID: feedURL) == nil)
        #expect(try Self.storedSubscription(in: context.container).autoAddToUpNext == 0)

        #expect(entryPoint.set(.bottom, appModel: appModel, context: context))

        #expect(appModel.library.podcastUpNextAutoAddPosition(forPodcastID: feedURL) == .bottom)
        #expect(try Self.storedSubscription(in: context.container).autoAddToUpNext == UpNextAutoAddPosition.bottom.stored)
        #expect(appModel.upNextAutoAddSettings.watermark(forPodcastID: feedURL) == Fixture.release(3))
        #expect(
            try Fixture.storedWatermarkRows(feedURL, in: context.container)
                == [UpNextAutoAddSettingsStore.encodeWatermark(Fixture.release(3))]
        )

        appModel.restorePlaybackSurfaceIfNeeded(modelContext: context)
        appModel.runUpNextAutoAddPass(modelContext: context)

        #expect(appModel.upNextQueue.items.isEmpty)
        #expect(appModel.upNextAutoAddSettings.watermark(forPodcastID: feedURL) == Fixture.release(3))
    }

    @Test(
        "A synced save that fails after the fresh watermark is written leaves the show off with no watermark row",
        arguments: AutoAddEntryPoint.allCases
    )
    func failedSyncedSaveAfterTheFreshWriteLeavesNoRow(entryPoint: AutoAddEntryPoint) async throws {
        let feedURL = Fixture.topFeedURL
        let librarySaves = SaveSwitch()
        let (appModel, context) = try await Self.sheetAppModel(
            librarySaves: librarySaves,
            storedWatermark: Fixture.release(1)
        )
        librarySaves.fails = true

        #expect(!entryPoint.set(.bottom, appModel: appModel, context: context))

        #expect(appModel.library.podcastUpNextAutoAddPosition(forPodcastID: feedURL) == nil)
        #expect(try Self.storedSubscription(in: context.container).autoAddToUpNext == 0)
        #expect(appModel.library.lastErrorMessage?.hasPrefix(entryPoint.syncedSaveFailurePrefix) == true)
        #expect(appModel.upNextAutoAddSettings.watermark(forPodcastID: feedURL) == nil)
        #expect(try Fixture.storedWatermarkRows(feedURL, in: context.container).isEmpty)
    }

    @Test("The show sheet's Save hands back the failed fresh write's message, not a library message left from earlier")
    func sheetSaveReportsTheFailedFreshWrite() async throws {
        let settingsSaves = SaveSwitch()
        let (appModel, context) = try await Self.sheetAppModel(settings: UpNextAutoAddSettingsStore(save: settingsSaves.save))
        // A refresh failed while the sheet was open; the root alert cannot
        // present over the sheet, so its message is still unread.
        let leftover = "The Internet connection appears to be offline."
        appModel.library.lastErrorMessage = leftover
        settingsSaves.fails = true

        let message = Self.saveSheet(.bottom, appModel: appModel, context: context)

        #expect(message == "Unable to record new episodes for Up Next: Simulated save failure")
        #expect(appModel.library.lastErrorMessage == leftover)
    }

    @Test("The show sheet's Save hands back the library's message when the synced save fails after the fresh write")
    func sheetSaveReportsTheFailedSyncedSave() async throws {
        let settingsSaves = SaveSwitch()
        let librarySaves = SaveSwitch()
        let (appModel, context) = try await Self.sheetAppModel(
            settings: UpNextAutoAddSettingsStore(save: settingsSaves.save),
            librarySaves: librarySaves
        )
        // An unread settings message from an earlier failure; the fresh
        // write's success leaves it in place.
        settingsSaves.fails = true
        #expect(!appModel.setUpNextAutoAddLimit(.ten, modelContext: context))
        settingsSaves.fails = false
        librarySaves.fails = true

        let message = Self.saveSheet(.bottom, appModel: appModel, context: context)

        #expect(message == "Unable to update playback settings: Simulated save failure")
        #expect(appModel.upNextAutoAddSettings.lastErrorMessage?.hasPrefix("Unable to update Auto Add Limit: ") == true)
    }

    @Test("The show sheet's Save hands back the removal's message when turning a show off saves but its row cannot be deleted")
    func sheetSaveReportsTheFailedRemoval() async throws {
        let feedURL = Fixture.topFeedURL
        let settingsSaves = SaveSwitch()
        let (appModel, context) = try await Self.sheetAppModel(
            settings: UpNextAutoAddSettingsStore(save: settingsSaves.save),
            position: .bottom,
            storedWatermark: Fixture.release(1)
        )
        settingsSaves.fails = true

        let message = Self.saveSheet(nil, appModel: appModel, context: context)

        #expect(message == "Unable to remove this show's Up Next settings: Simulated save failure")
        #expect(appModel.library.podcastUpNextAutoAddPosition(forPodcastID: feedURL) == nil)
        #expect(appModel.upNextAutoAddSettings.watermark(forPodcastID: feedURL) == Fixture.release(1))
    }

    /// The show sheet's Save with a 30-second intro skip and the global
    /// speed; nil once everything saved.
    private static func saveSheet(
        _ position: UpNextAutoAddPosition?,
        appModel: OpenCastAppModel,
        context: ModelContext
    ) -> String? {
        appModel.setPodcastPlaybackSettings(
            PodcastPlaybackSkipSettings(skipIntroSeconds: 30),
            rateOverride: nil,
            upNextAutoAdd: position,
            feedURL: Fixture.topFeedURL,
            modelContext: context
        )
    }

    /// The Top feed's subscription as stored, read through a fresh context.
    private static func storedSubscription(in container: ModelContainer) throws -> SubscriptionRecord {
        try #require(
            ModelContext(container)
                .fetch(FetchDescriptor<SubscriptionRecord>())
                .first { $0.feedURL == Fixture.topFeedURL }
        )
    }

    /// An app model, hydrated, subscribed to the Top feed with releases on
    /// days 1 to 3, Auto Add to Up Next at `position` (off by default) and,
    /// with `storedWatermark`, a watermark row. `librarySaves` is the
    /// library's synced-store save seam.
    private static func sheetAppModel(
        settings: UpNextAutoAddSettingsStore = UpNextAutoAddSettingsStore(),
        librarySaves: SaveSwitch = SaveSwitch(),
        position: UpNextAutoAddPosition? = nil,
        storedWatermark: Date? = nil
    ) async throws -> (OpenCastAppModel, ModelContext) {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let cache = SQLiteLocalLibraryCacheStore.inMemory()
        let feedURL = Fixture.topFeedURL
        try await cache.upsertCache(from: Fixture.snapshot(feedURL: feedURL, releaseDays: [1, 2, 3]), refreshedAt: Fixture.base)
        context.insert(
            SubscriptionRecord(
                feedURL: feedURL,
                title: "Auto Add Show",
                autoAddToUpNext: UpNextAutoAddPosition.stored(position)
            )
        )
        if let storedWatermark {
            context.insert(
                LocalPreferenceRecord(
                    key: UpNextAutoAddSettingsStore.watermarkKeyPrefix + feedURL,
                    value: UpNextAutoAddSettingsStore.encodeWatermark(storedWatermark)
                )
            )
        }
        try context.save()
        let appModel = OpenCastAppModel(
            library: LibraryStore(localCache: cache, savePlaybackSkipSettingsModelContext: librarySaves.save),
            upNextAutoAddSettings: settings,
            allowsAutomaticFeedRefresh: false
        )
        await appModel.ensureCoreStoresLoaded(modelContext: context)
        return (appModel, context)
    }
}

/// The two places a listener turns a show's Auto Add to Up Next on or off:
/// Settings › Playback › Auto Add to Up Next, and the show's Playback
/// Settings sheet, whose Save also carries its skips and speed.
enum AutoAddEntryPoint: CaseIterable, Sendable {
    case settingsRow
    case showSheet

    @MainActor
    func set(_ position: UpNextAutoAddPosition?, appModel: OpenCastAppModel, context: ModelContext) -> Bool {
        switch self {
        case .settingsRow:
            appModel.setUpNextAutoAddPosition(position, forPodcastID: UpNextAutoAddFixture.topFeedURL, modelContext: context)
        case .showSheet:
            appModel.setPodcastPlaybackSettings(
                PodcastPlaybackSkipSettings(skipIntroSeconds: 30),
                rateOverride: nil,
                upNextAutoAdd: position,
                feedURL: UpNextAutoAddFixture.topFeedURL,
                modelContext: context
            ) == nil
        }
    }

    var syncedSaveFailurePrefix: String {
        switch self {
        case .settingsRow:
            "Unable to update Add to Up Next: "
        case .showSheet:
            "Unable to update playback settings: "
        }
    }
}

/// Flips a save seam between the real save and a failure.
private final class SaveSwitch {
    var fails = false
    /// When set, this many more saves go through and every later one fails.
    var savesBeforeFailing: Int?
    /// This many more saves fail, and the ones after go through.
    var failuresRemaining = 0

    func save(_ context: ModelContext) throws {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw UpNextAutoAddSaveFailure()
        }
        if let remaining = savesBeforeFailing {
            guard remaining > 0 else {
                throw UpNextAutoAddSaveFailure()
            }
            savesBeforeFailing = remaining - 1
        } else if fails {
            throw UpNextAutoAddSaveFailure()
        }
        try context.save()
    }
}

private struct UpNextAutoAddSaveFailure: LocalizedError {
    var errorDescription: String? {
        "Simulated save failure"
    }
}

@MainActor
private final class UpNextAutoAddFixture {
    static let base = Date(timeIntervalSince1970: 1_780_000_000)
    static let topFeedURL = "https://example.com/a-top.xml"
    static let bottomFeedURL = "https://example.com/b-bottom.xml"

    /// Day `day` after `base`; the fixture's clock starts on day 30.
    static func release(_ day: Int) -> Date {
        base.addingTimeInterval(Double(day) * 86_400)
    }

    let context: ModelContext
    let cache = SQLiteLocalLibraryCacheStore.inMemory()
    let librarySaves = SaveSwitch()
    let queueSaves = SaveSwitch()
    let settingsSaves = SaveSwitch()
    let library: LibraryStore
    let upNextQueue: UpNextQueueStore
    let settings: UpNextAutoAddSettingsStore
    var now = UpNextAutoAddFixture.release(30)
    var currentEpisodeID: String?
    private(set) var coordinator: UpNextAutoAddCoordinator!

    private init(context: ModelContext) {
        self.context = context
        library = LibraryStore(localCache: cache, savePlaybackSkipSettingsModelContext: librarySaves.save)
        upNextQueue = UpNextQueueStore(saveModelContext: queueSaves.save)
        settings = UpNextAutoAddSettingsStore(save: settingsSaves.save)
    }

    static func make(subscribedFeedURLs: [String] = [topFeedURL]) async throws -> UpNextAutoAddFixture {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let fixture = UpNextAutoAddFixture(context: ModelContext(container))
        fixture.coordinator = UpNextAutoAddCoordinator(
            library: fixture.library,
            upNextQueue: fixture.upNextQueue,
            settings: fixture.settings,
            isCurrentEpisode: { [unowned fixture] episodeID in fixture.currentEpisodeID == episodeID },
            now: { [unowned fixture] in fixture.now }
        )
        for feedURL in subscribedFeedURLs {
            fixture.context.insert(SubscriptionRecord(feedURL: feedURL, title: slug(feedURL)))
        }
        try fixture.context.save()
        fixture.settings.load(modelContext: fixture.context)
        await fixture.library.load(modelContext: fixture.context)
        return fixture
    }

    /// Episode `i` of a feed is released on `releaseDays[i]`; indices in
    /// `audioLessIndices` have no enclosure.
    static func snapshot(feedURL: String, releaseDays: [Int], audioLessIndices: Set<Int> = []) -> FeedSnapshot {
        let url = URL(string: feedURL)!
        let podcastID = URLCanonicalizer.podcastID(for: url)
        let title = slug(feedURL)
        return FeedSnapshot(
            podcast: Podcast(id: podcastID, feedURL: url, title: title),
            episodes: releaseDays.enumerated().map { index, day in
                Episode(
                    id: EpisodeID(rawValue: episodeID(index, in: feedURL)),
                    podcastID: podcastID,
                    podcastTitle: title,
                    title: "Episode \(index)",
                    publishedAt: release(day),
                    duration: 600,
                    audioURL: audioLessIndices.contains(index)
                        ? nil
                        : URL(string: "https://cdn.example.com/\(title)-\(index).mp3"),
                    guid: episodeID(index, in: feedURL)
                )
            }
        )
    }

    static func episodeID(_ index: Int, in feedURL: String) -> String {
        "\(slug(feedURL))-\(index)"
    }

    private static func slug(_ feedURL: String) -> String {
        URL(string: feedURL)!.deletingPathExtension().lastPathComponent
    }

    /// Replaces a feed's cached episodes and reloads the library.
    func publish(
        _ feedURL: String = UpNextAutoAddFixture.topFeedURL,
        releaseDays: [Int],
        audioLessIndices: Set<Int> = []
    ) async throws {
        try await cache.upsertCache(
            from: Self.snapshot(feedURL: feedURL, releaseDays: releaseDays, audioLessIndices: audioLessIndices),
            refreshedAt: Self.base
        )
        await library.load(modelContext: context)
    }

    func id(_ index: Int, in feedURL: String = UpNextAutoAddFixture.topFeedURL) -> String {
        Self.episodeID(index, in: feedURL)
    }

    func episode(_ index: Int, in feedURL: String = UpNextAutoAddFixture.topFeedURL) throws -> EpisodeListItemSnapshot {
        try #require(library.episode(with: id(index, in: feedURL)))
    }

    func watermark(_ feedURL: String = UpNextAutoAddFixture.topFeedURL) -> Date? {
        settings.watermark(forPodcastID: feedURL)
    }

    var queuedIDs: [String] {
        upNextQueue.items.map(\.episodeID)
    }

    func handIDs(_ count: Int) -> [String] {
        (0..<count).map { "hand-\($0)" }
    }

    /// Queues hand-picked rows from a show Auto Add to Up Next does not
    /// follow; they count toward the limit like any other row.
    func queueHandRows(_ count: Int) {
        let rows = handIDs(count).map { episodeID in
            EpisodeListItemSnapshot.fixture(
                episodeID: episodeID,
                podcastID: "https://example.com/hand.xml",
                audioURL: "https://cdn.example.com/\(episodeID).mp3",
                guid: episodeID
            )
        }
        #expect(upNextQueue.enqueueLast(rows, source: nil, modelContext: context))
    }

    func markPlayed(_ index: Int, in feedURL: String = UpNextAutoAddFixture.topFeedURL) throws {
        context.insert(
            EpisodeProgressRecord(episodeID: id(index, in: feedURL), podcastID: feedURL, position: 600, duration: 600, isPlayed: true)
        )
        try context.save()
        library.refreshProgressRecords(modelContext: context)
    }

    func storedAutoAddToUpNext(_ feedURL: String) throws -> Int? {
        try ModelContext(context.container)
            .fetch(FetchDescriptor<SubscriptionRecord>())
            .first { $0.feedURL == feedURL }?
            .autoAddToUpNext
    }

    func storedWatermarkRows(_ feedURL: String) throws -> [String] {
        try Self.storedWatermarkRows(feedURL, in: context.container)
    }

    static func storedWatermarkRows(_ feedURL: String, in container: ModelContainer) throws -> [String] {
        let key = UpNextAutoAddSettingsStore.watermarkKeyPrefix + feedURL
        return try ModelContext(container)
            .fetch(FetchDescriptor<LocalPreferenceRecord>())
            .filter { $0.key == key }
            .map(\.value)
    }

    /// Deletes the stored row behind the settings store's back, as a lost
    /// row would be.
    func deleteStoredWatermarkRows(_ feedURL: String) throws {
        let rowContext = ModelContext(context.container)
        try LocalPreferenceRecord.deletePreferences(
            forKey: UpNextAutoAddSettingsStore.watermarkKeyPrefix + feedURL,
            modelContext: rowContext
        )
        try rowContext.save()
    }

    /// The persisted queue in stored order, read through a fresh context.
    func storedQueueIDs() throws -> [String] {
        try ModelContext(context.container)
            .fetch(FetchDescriptor<UpNextQueueItemRecord>(sortBy: [SortDescriptor(\.sequence)]))
            .map(\.episodeID)
    }
}
