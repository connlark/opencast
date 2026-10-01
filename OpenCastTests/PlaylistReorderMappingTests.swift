import Foundation
import Testing
@testable import OpenCast

@Suite("Playlist reorder mapping")
struct PlaylistReorderMappingTests {
    @Test("With no hidden rows the offsets pass through unchanged")
    func noHiddenRowsIsIdentity() {
        let itemIDs = ["a", "b", "c", "d"]

        let down = PlaylistReorderMapping.fullOffsets(
            visibleItemIDs: itemIDs,
            allItemIDs: itemIDs,
            fromOffsets: [0],
            toOffset: 3
        )
        let up = PlaylistReorderMapping.fullOffsets(
            visibleItemIDs: itemIDs,
            allItemIDs: itemIDs,
            fromOffsets: [3],
            toOffset: 0
        )
        let several = PlaylistReorderMapping.fullOffsets(
            visibleItemIDs: itemIDs,
            allItemIDs: itemIDs,
            fromOffsets: [1, 2],
            toOffset: 4
        )

        #expect(down.fromOffsets == [0])
        #expect(down.toOffset == 3)
        #expect(up.fromOffsets == [3])
        #expect(up.toOffset == 0)
        #expect(several.fromOffsets == [1, 2])
        #expect(several.toOffset == 4)
    }

    @Test("Hidden rows between visible ones keep their place")
    func hiddenRowsBetweenVisibleRows() {
        let allItemIDs = ["a", "hidden-1", "b", "hidden-2", "c"]
        let visibleItemIDs = ["a", "b", "c"]

        let upward = PlaylistReorderMapping.fullOffsets(
            visibleItemIDs: visibleItemIDs,
            allItemIDs: allItemIDs,
            fromOffsets: [2],
            toOffset: 1
        )
        let downward = PlaylistReorderMapping.fullOffsets(
            visibleItemIDs: visibleItemIDs,
            allItemIDs: allItemIDs,
            fromOffsets: [0],
            toOffset: 2
        )

        // "c" lands just before "b", after the hidden row that follows "a".
        #expect(upward.fromOffsets == [4])
        #expect(upward.toOffset == 2)
        // "a" lands just before "c", after the hidden row that follows "b".
        #expect(downward.fromOffsets == [0])
        #expect(downward.toOffset == 4)
    }

    @Test("A move to the end of the visible rows goes to the end of the playlist")
    func moveToEndMapsToFullCount() {
        let allItemIDs = ["a", "b", "hidden-1", "c", "hidden-2"]
        let visibleItemIDs = ["a", "b", "c"]

        let mapped = PlaylistReorderMapping.fullOffsets(
            visibleItemIDs: visibleItemIDs,
            allItemIDs: allItemIDs,
            fromOffsets: [0, 1],
            toOffset: visibleItemIDs.count
        )

        #expect(mapped.fromOffsets == [0, 1])
        #expect(mapped.toOffset == allItemIDs.count)
    }
}
