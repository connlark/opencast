import Foundation

/// Translates a move made in a filtered list (Hide Played) into offsets over
/// the playlist's full item order, which is what the store reorders.
nonisolated enum PlaylistReorderMapping {
    /// A destination at the end of the visible rows maps to the end of the
    /// full list; any other destination lands just before the visible row it
    /// names, so hidden rows between two visible ones keep their place.
    static func fullOffsets(
        visibleItemIDs: [String],
        allItemIDs: [String],
        fromOffsets: IndexSet,
        toOffset: Int
    ) -> (fromOffsets: IndexSet, toOffset: Int) {
        var fullIndexByID: [String: Int] = [:]
        for (index, itemID) in allItemIDs.enumerated() where fullIndexByID[itemID] == nil {
            fullIndexByID[itemID] = index
        }

        var mappedOffsets = IndexSet()
        for offset in fromOffsets where visibleItemIDs.indices.contains(offset) {
            if let fullIndex = fullIndexByID[visibleItemIDs[offset]] {
                mappedOffsets.insert(fullIndex)
            }
        }

        let mappedDestination: Int
        if visibleItemIDs.indices.contains(toOffset),
           let fullIndex = fullIndexByID[visibleItemIDs[toOffset]] {
            mappedDestination = fullIndex
        } else {
            mappedDestination = allItemIDs.count
        }
        return (mappedOffsets, mappedDestination)
    }
}
