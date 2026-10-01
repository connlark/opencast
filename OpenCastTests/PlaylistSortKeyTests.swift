import Foundation
import SwiftData
import Testing
@testable import OpenCast

@MainActor
@Suite("Playlist sort keys")
struct PlaylistSortKeyTests {
    @Test("Head, tail and neighbour inserts sort between their bounds")
    func insertsSortBetweenBounds() {
        let only = PlaylistSortKey.between(nil, nil)
        let head = PlaylistSortKey.first(before: only)
        let tail = PlaylistSortKey.last(after: only)
        let afterHead = PlaylistSortKey.between(head, only)
        let beforeTail = PlaylistSortKey.between(only, tail)

        let ordered = [head, afterHead, only, beforeTail, tail]
        #expect(ordered == ordered.sorted())
        #expect(Set(ordered).count == ordered.count)
        #expect(ordered.allSatisfy(PlaylistSortKey.isValid))
        #expect(PlaylistSortKey.first(before: nil) == only)
        #expect(PlaylistSortKey.last(after: nil) == only)
    }

    @Test(
        "A key between tight neighbours sorts strictly between them",
        arguments: [
            (nil, "1"),
            (nil, "01"),
            ("z", nil),
            ("zz", nil),
            ("a", "b"),
            ("a", "a1"),
            ("a", "a01"),
            ("09", "1"),
            ("49", "5"),
            ("a11", "a9"),
            ("0z", "1")
        ] as [(String?, String?)]
    )
    func tightNeighbours(lower: String?, upper: String?) {
        let key = PlaylistSortKey.between(lower, upper)

        #expect(PlaylistSortKey.isValid(key))
        if let lower {
            #expect(lower < key)
        }
        if let upper {
            #expect(key < upper)
        }
    }

    @Test("Repeated inserts at interior positions keep plain string order")
    func interiorInsertsKeepOrder() {
        var keys = [PlaylistSortKey.between(nil, nil)]

        for insertion in 0..<500 {
            let position = (insertion * 7) % (keys.count + 1)
            let lower = position > 0 ? keys[position - 1] : nil
            let upper = position < keys.count ? keys[position] : nil
            keys.insert(PlaylistSortKey.between(lower, upper), at: position)
        }

        #expect(keys == keys.sorted())
        #expect(Set(keys).count == keys.count)
        #expect(keys.allSatisfy(PlaylistSortKey.isValid))
    }

    @Test("Renumbered keys are ordered, valid and as short as the count allows")
    func renumberedKeysAreShort() {
        #expect(PlaylistSortKey.renumbered(count: 0).isEmpty)
        #expect(PlaylistSortKey.renumbered(count: 3) == ["9", "i", "r"])

        let expectedLengths = [1: 1, 3: 1, 35: 1, 36: 2, 1000: 2, 1295: 2, 1296: 3]
        for (count, expectedLength) in expectedLengths {
            let keys = PlaylistSortKey.renumbered(count: count)

            #expect(keys.count == count)
            #expect(keys == keys.sorted(), "Renumbering \(count) keys is out of order")
            #expect(Set(keys).count == count, "Renumbering \(count) keys produced duplicates")
            #expect(keys.allSatisfy(PlaylistSortKey.isValid), "Renumbering \(count) keys produced an invalid key")
            #expect(keys.map(\.count).max() == expectedLength, "Renumbering \(count) keys used the wrong length")
        }
    }

    @Test("A thousand head inserts stay valid with renumbering when a key grows too long")
    func thousandHeadInserts() {
        var keys: [String] = []
        var renumberCount = 0

        for _ in 0..<1000 {
            let previousHead = keys.first
            let key = PlaylistSortKey.first(before: previousHead)

            #expect(PlaylistSortKey.isValid(key))
            if let previousHead {
                #expect(key < previousHead)
            }

            keys.insert(key, at: 0)
            if PlaylistSortKey.needsRenumbering(key) {
                keys = PlaylistSortKey.renumbered(count: keys.count)
                renumberCount += 1
            }
        }

        #expect(keys.count == 1000)
        #expect(keys == keys.sorted())
        #expect(!keys.contains(where: PlaylistSortKey.needsRenumbering))
        #expect(renumberCount == 2, "A thousand head inserts took \(renumberCount) renumbers")
    }

    @Test("Renumbering starts past the threshold length")
    func renumberingThreshold() {
        #expect(PlaylistSortKey.renumberThreshold == 64)
        #expect(!PlaylistSortKey.needsRenumbering(String(repeating: "1", count: 64)))
        #expect(PlaylistSortKey.needsRenumbering(String(repeating: "1", count: 65)))
    }

    @Test("Only non-empty alphabet keys without a trailing zero are valid")
    func keyValidity() {
        #expect(PlaylistSortKey.alphabet.count == 36)
        #expect(PlaylistSortKey.isValid("a"))
        #expect(PlaylistSortKey.isValid("0z1"))
        #expect(!PlaylistSortKey.isValid(""))
        #expect(!PlaylistSortKey.isValid("a0"))
        #expect(!PlaylistSortKey.isValid("A"))
        #expect(!PlaylistSortKey.isValid("a-b"))
    }

    @Test("A lexical SwiftData sort returns rows in plain string order")
    func lexicalFetchMatchesStringOrder() throws {
        let container = try OpenCastModelContainerFactory.make(inMemory: true)
        let context = ModelContext(container)
        // "a9" / "a11" and "2" / "11" are the pairs a numeric-aware
        // comparator would swap.
        var keySet = Set(PlaylistSortKey.renumbered(count: 40))
        keySet.formUnion(["a9", "a11", "2", "11", "0z", "z", "zi"])
        keySet.insert(PlaylistSortKey.between("a11", "a9"))
        keySet.insert(PlaylistSortKey.first(before: "0z"))
        let sortedKeys = keySet.sorted()

        for (index, key) in sortedKeys.reversed().enumerated() {
            context.insert(
                PlaylistItemRecord(
                    playlistID: "sort-key-fixture",
                    episodeID: "episode-\(index)",
                    podcastID: "https://example.com/feed.xml",
                    sortKey: key,
                    episodeTitle: "Episode \(index)",
                    podcastTitle: "Example Show"
                )
            )
        }
        try context.save()

        let fetched = try ModelContext(container).fetch(
            FetchDescriptor<PlaylistItemRecord>(
                sortBy: [SortDescriptor(\.sortKey, comparator: .lexical)]
            )
        )

        #expect(fetched.map(\.sortKey) == sortedKeys)
    }
}
