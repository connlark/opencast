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

        // Applying the same instances one at a time, in an order the store
        // would never hand back, must converge on the descriptor's order —
        // the comparator and the descriptor share sort keys by contract.
        var incremental = EpisodeProgressIndex()
        for record in fetched.reversed() {
            _ = incremental.apply(record)
        }

        var refetched = EpisodeProgressIndex()
        _ = refetched.replaceAll(fetched)

        // Array order only: apply's latest-per-episode indexing assumes each
        // applied record is its episode's newest write, which a reversed
        // replay deliberately violates.
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

        // A refetch from the same context hands back the same registered
        // instances: no identity change, no revision owed.
        let secondFetch = try context.fetch(EpisodeProgressIndex.allRecordsDescriptor())
        let sameInstanceReplaceChanged = index.replaceAll(secondFetch)
        #expect(!sameInstanceReplaceChanged)

        // A fresh instance for an already-indexed episode changes identity.
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

        // A brand-new episode changes membership.
        let newcomer = EpisodeProgressRecord(
            episodeID: "member-3",
            podcastID: podcastID,
            position: 5,
            duration: 100
        )
        let newcomerApplyChanged = index.apply(newcomer)
        #expect(newcomerApplyChanged)

        // Dropping an episode changes membership.
        let droppingReplaceChanged = index.replaceAll(secondFetch)
        #expect(droppingReplaceChanged)
    }
}
