import Foundation
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Episode progress index")
struct EpisodeProgressIndexTests {
    @Test("Incremental insertion order matches a descriptor refetch order")
    func incrementalInsertionOrderMatchesDescriptorRefetchOrder() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = Date(timeIntervalSince1970: 1_700_000_100)
        let fixtures: [(String, String, TimeInterval, TimeInterval?, Date)] = [
            ("https://example.com/b.xml", "episode-1", 10, 100, t0),
            ("https://example.com/b.xml", "episode-1", 20, 100, t1),
            ("https://example.com/b.xml", "episode-2", 5, nil, t0),
            ("https://example.com/b.xml", "episode-2", 5, 300, t0),
            ("https://example.com/a.xml", "episode-3", 0, 50, t1),
            ("https://example.com/c.xml", "episode-4", 42, 3_600, t0)
        ]
        for (podcastID, episodeID, position, duration, updatedAt) in fixtures {
            context.insert(
                EpisodeProgressRecord(
                    episodeID: episodeID,
                    podcastID: podcastID,
                    position: position,
                    duration: duration,
                    updatedAt: updatedAt
                )
            )
        }
        try context.save()

        let fetched = try context.fetch(EpisodeProgressIndex.allRecordsDescriptor())
        #expect(fetched.count == fixtures.count)

        var incremental = EpisodeProgressIndex()
        for record in fetched.reversed() {
            _ = incremental.apply(record)
        }

        var refetched = EpisodeProgressIndex()
        _ = refetched.replaceAll(fetched)

        // Array order only: a reversed replay breaks apply's assumption that each record is its episode's newest write.
        #expect(incremental.records.elementsEqual(fetched, by: ===))
        #expect(incremental.records.elementsEqual(refetched.records, by: ===))
    }

    @Test("Re-applying an indexed record neither duplicates nor reports change")
    func reapplyingIndexedRecordNeitherDuplicatesNorReportsChange() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let record = EpisodeProgressRecord(
            episodeID: "stable-episode",
            podcastID: "https://example.com/stable.xml",
            position: 30,
            duration: 120
        )
        context.insert(record)
        try context.save()

        var index = EpisodeProgressIndex()
        let firstApplyChanged = index.apply(record)
        let secondApplyChanged = index.apply(record)
        #expect(firstApplyChanged)
        #expect(!secondApplyChanged)
        #expect(index.records.count == 1)
        #expect(index.latest(for: "stable-episode") === record)
    }

    @Test("Membership changes report; same-instance replacements do not")
    func membershipChangesReportSameInstanceReplacementsDoNot() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let podcastID = "https://example.com/membership.xml"
        for episodeID in ["member-1", "member-2"] {
            context.insert(
                EpisodeProgressRecord(
                    episodeID: episodeID,
                    podcastID: podcastID,
                    position: 10,
                    duration: 100
                )
            )
        }
        try context.save()

        var index = EpisodeProgressIndex()
        let firstFetch = try context.fetch(EpisodeProgressIndex.allRecordsDescriptor())
        let initialReplaceChanged = index.replaceAll(firstFetch)
        #expect(initialReplaceChanged)

        // A refetch from the same context returns the same registered instances.
        let secondFetch = try context.fetch(EpisodeProgressIndex.allRecordsDescriptor())
        let sameInstanceReplaceChanged = index.replaceAll(secondFetch)
        #expect(!sameInstanceReplaceChanged)

        let replacement = EpisodeProgressRecord(
            episodeID: "member-1",
            podcastID: podcastID,
            position: 50,
            duration: 100,
            updatedAt: Date.now.addingTimeInterval(60)
        )
        let replacementApplyChanged = index.apply(replacement)
        #expect(replacementApplyChanged)
        #expect(index.latest(for: "member-1") === replacement)

        let newcomer = EpisodeProgressRecord(
            episodeID: "member-3",
            podcastID: podcastID,
            position: 5,
            duration: 100
        )
        let newcomerApplyChanged = index.apply(newcomer)
        #expect(newcomerApplyChanged)

        let droppingReplaceChanged = index.replaceAll(secondFetch)
        #expect(droppingReplaceChanged)
    }

    @Test("Same-instant copies that differ only in their archive index the same copy in either order")
    func fullTiesIndexTheSameCopyInEitherOrder() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        func copy(archivedAt: Date?, dedupeUUID: String) -> EpisodeProgressRecord {
            let record = EpisodeProgressRecord(
                episodeID: "tied",
                podcastID: "https://example.com/tied.xml",
                position: 30,
                duration: 120,
                archivedAt: archivedAt,
                updatedAt: instant,
                dedupeUUID: dedupeUUID
            )
            context.insert(record)
            return record
        }
        let archived = copy(archivedAt: instant, dedupeUUID: "bbbbbbbb")
        let unarchived = copy(archivedAt: nil, dedupeUUID: "aaaaaaaa")
        let laterArchive = copy(archivedAt: instant.addingTimeInterval(10), dedupeUUID: "cccccccc")
        let smallerIdentity = copy(archivedAt: nil, dedupeUUID: "00000000")
        try context.save()

        let cases: [(copies: [EpisodeProgressRecord], winner: EpisodeProgressRecord)] = [
            ([archived, unarchived], archived),
            ([archived, laterArchive], laterArchive),
            ([unarchived, smallerIdentity], smallerIdentity)
        ]
        for (copies, winner) in cases {
            for order in [copies, Array(copies.reversed())] {
                #expect(EpisodeProgressIndex.latestRecordsByEpisodeID(order)["tied"] === winner)
            }
        }
        #expect(EpisodeProgressIndex.archivedEpisodeIDs(in: [archived, unarchived]) == ["tied"])
        #expect(EpisodeProgressIndex.archivedEpisodeIDs(in: [unarchived, archived]) == ["tied"])
    }

    @Test("Same-instant copies whose durations are nil and zero reach the final tie-break in either order")
    func nilAndZeroDurationsReachTheFinalTieBreak() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        func copy(duration: TimeInterval?, archivedAt: Date?, dedupeUUID: String) -> EpisodeProgressRecord {
            let record = EpisodeProgressRecord(
                episodeID: "tied",
                podcastID: "https://example.com/tied.xml",
                position: 0,
                duration: duration,
                archivedAt: archivedAt,
                updatedAt: instant,
                dedupeUUID: dedupeUUID
            )
            context.insert(record)
            return record
        }
        let archivedWithoutDuration = copy(duration: nil, archivedAt: instant, dedupeUUID: "bbbbbbbb")
        let unarchivedAtZero = copy(duration: 0, archivedAt: nil, dedupeUUID: "aaaaaaaa")
        let archivedAtZero = copy(duration: 0, archivedAt: instant, dedupeUUID: "dddddddd")
        let unarchivedWithoutDuration = copy(duration: nil, archivedAt: nil, dedupeUUID: "cccccccc")
        let smallerIdentityWithoutDuration = copy(duration: nil, archivedAt: nil, dedupeUUID: "00000000")
        try context.save()

        let cases: [(copies: [EpisodeProgressRecord], winner: EpisodeProgressRecord)] = [
            ([archivedWithoutDuration, unarchivedAtZero], archivedWithoutDuration),
            ([archivedAtZero, unarchivedWithoutDuration], archivedAtZero),
            ([unarchivedAtZero, smallerIdentityWithoutDuration], smallerIdentityWithoutDuration)
        ]
        for (copies, winner) in cases {
            for order in [copies, Array(copies.reversed())] {
                #expect(EpisodeProgressIndex.latestRecordsByEpisodeID(order)["tied"] === winner)
            }
        }
        for order in [[archivedWithoutDuration, unarchivedAtZero], [unarchivedAtZero, archivedWithoutDuration]] {
            #expect(EpisodeProgressIndex.archivedEpisodeIDs(in: order) == ["tied"])
        }
    }
}
