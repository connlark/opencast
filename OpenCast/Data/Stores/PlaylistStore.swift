import Foundation
import Observation
import OpenCastCore
import SwiftData

/// Owns the synced playlists with `UpNextQueueStore`'s save and rollback
/// mechanics, minus consumption: playback never removes an item, load never
/// prunes rows whose episode stopped resolving (they render from their
/// fallbacks), and adding an existing member skips it rather than moving it.
/// Every save dirties a playlist, item or playlist tombstone row, because it
/// carries a self-save credit that would otherwise swallow a remote change.
@Observable
final class PlaylistStore {
    private typealias ListedState = (
        playlists: [PlaylistSummary],
        itemsByPlaylistID: [String: [PlaylistItem]],
        needsRepair: Bool
    )

    private(set) var playlists: [PlaylistSummary] = []
    private(set) var itemsByPlaylistID: [String: [PlaylistItem]] = [:]
    private(set) var lastErrorMessage: String?
    var sortOrder: PlaylistSortOrder = .recentlyUpdated {
        didSet {
            guard sortOrder != oldValue else {
                return
            }
            playlists = Self.sorted(playlists, by: sortOrder)
        }
    }

    @ObservationIgnored var onPlaylistsChanged: (() -> Void)?
    /// Smart playlist evaluations, keyed by the tokens each rule reads; the
    /// app model fills it and this store drops entries with their playlists.
    @ObservationIgnored let smartEvaluations = SmartPlaylistEvaluationCache()
    @ObservationIgnored private let saveSyncedStore: (ModelContext) throws -> Void
    @ObservationIgnored private let now: () -> Date
    /// Re-keys staged by `migrateEpisodeSidecars` until the reconciliation
    /// reports whether its save committed.
    @ObservationIgnored private var stagedIdentityMigration: StagedIdentityMigration?

    /// `saveSyncedStore` is the synced-store save (the self-save ledger in the
    /// app); `now` is the test seam for deterministic timestamps.
    init(
        saveSyncedStore: @escaping (ModelContext) throws -> Void,
        now: @escaping () -> Date = { .now }
    ) {
        self.saveSyncedStore = saveSyncedStore
        self.now = now
    }

    func load(modelContext: ModelContext) {
        stagedIdentityMigration = nil
        do {
            let state = try fetchListedState(modelContext: modelContext)
            playlists = state.playlists
            itemsByPlaylistID = state.itemsByPlaylistID
            lastErrorMessage = nil
            onPlaylistsChanged?()
        } catch {
            modelContext.rollback()
            lastErrorMessage = "Unable to load playlists: \(error.localizedDescription)"
        }
    }

    /// Rereads the rows after something outside this store may have changed
    /// them (an import, a repair pass) and publishes only on a difference.
    ///
    /// It never rolls back or drops a staged re-key: it wrote nothing, and the
    /// context is shared with writers whose pending changes are not its own.
    /// The full fetch is deliberate, since an identity re-key and a feed-move
    /// rule rewrite leave `updatedAt` alone and a cheaper probe would miss them.
    @discardableResult
    func reload(modelContext: ModelContext) -> PlaylistReloadChange {
        let state: ListedState
        do {
            state = try fetchListedState(modelContext: modelContext)
        } catch {
            lastErrorMessage = "Unable to reload playlists: \(error.localizedDescription)"
            return PlaylistReloadChange()
        }

        var change = PlaylistReloadChange(needsRepair: state.needsRepair)
        // A playlist emptied in place keeps an empty entry in memory, while
        // the rows produce no entry at all; neither is a change.
        guard state.playlists != playlists
            || state.itemsByPlaylistID != itemsByPlaylistID.filter({ !$0.value.isEmpty })
        else {
            return change
        }

        let previousNames = Dictionary(
            playlists.map { ($0.playlistID, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        let currentNames = Dictionary(
            state.playlists.map { ($0.playlistID, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        change.didChange = true
        change.removedPlaylistIDs = Set(previousNames.keys).subtracting(currentNames.keys)
        change.renamedPlaylistIDs = Set(
            currentNames.compactMap { playlistID, name in
                guard let previousName = previousNames[playlistID], previousName != name else {
                    return nil
                }
                return playlistID
            }
        )

        playlists = state.playlists
        itemsByPlaylistID = state.itemsByPlaylistID
        for playlistID in change.removedPlaylistIDs {
            smartEvaluations.remove(playlistID)
        }
        onPlaylistsChanged?()
        return change
    }

    /// A smart playlist stores `rule`, or the default rule without one; a
    /// manual playlist ignores it.
    @discardableResult
    func create(
        name: String,
        kind: PlaylistKind,
        rule: PlaylistRule? = nil,
        origin: PlaylistOrigin = .user,
        modelContext: ModelContext
    ) -> PlaylistSummary? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            lastErrorMessage = "Unable to create the playlist: enter a name."
            return nil
        }

        let timestamp = now()
        let tintKey = kind == .smart
            ? PlaylistTint.next(after: playlists.compactMap(\.tintKey)).rawValue
            : nil
        let record = PlaylistRecord(
            name: trimmedName,
            kind: kind,
            ruleJSON: kind == .smart ? (rule ?? .default).normalized().encodedJSON() : nil,
            tintKey: tintKey,
            origin: origin,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let summary = Self.summary(from: record, items: [])
        let previousPlaylists = playlists
        playlists = Self.sorted(playlists + [summary], by: sortOrder)

        do {
            modelContext.insert(record)
            try saveSyncedStore(modelContext)
            didMutate()
            return summary
        } catch {
            modelContext.rollback()
            playlists = previousPlaylists
            lastErrorMessage = "Unable to create the playlist: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func rename(_ playlistID: String, to name: String, modelContext: ModelContext) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            lastErrorMessage = "Unable to rename the playlist: enter a name."
            return false
        }

        return updatePlaylist(
            playlistID,
            failure: "Unable to rename the playlist",
            modelContext: modelContext
        ) { summary in
            summary.name = trimmedName
        }
    }

    @discardableResult
    func setHidesPlayed(
        _ hidesPlayed: Bool,
        for playlistID: String,
        modelContext: ModelContext
    ) -> Bool {
        updatePlaylist(
            playlistID,
            failure: "Unable to update Hide Played",
            modelContext: modelContext
        ) { summary in
            summary.hidesPlayed = hidesPlayed
        }
    }

    /// Stores a smart playlist's rule in its canonical form; an identical
    /// rule is a no-op. A rule this build cannot read is never overwritten,
    /// so an older app cannot clobber a newer version's rule.
    @discardableResult
    func setRule(
        _ rule: PlaylistRule,
        for playlistID: String,
        modelContext: ModelContext
    ) -> Bool {
        let failure = "Unable to update the playlist rules"
        guard let current = playlists.first(where: { $0.playlistID == playlistID }) else {
            lastErrorMessage = "\(failure) because the playlist no longer exists."
            return false
        }
        guard current.kind == .smart else {
            lastErrorMessage = "\(failure)."
            return false
        }
        guard !current.hasUnreadableRule else {
            lastErrorMessage = "These rules need a newer version of the app."
            return false
        }

        // Decided on the decoded rule: a row stored without JSON, or in a
        // non-canonical encoding, must not save and bump for a re-picked value.
        let normalizedRule = rule.normalized()
        guard normalizedRule != current.rule else {
            return true
        }
        return updatePlaylist(
            playlistID,
            failure: failure,
            modelContext: modelContext
        ) { summary in
            summary.rule = normalizedRule
            summary.ruleJSON = normalizedRule.encodedJSON()
        }
    }

    @discardableResult
    func delete(_ playlistID: String, modelContext: ModelContext) -> Bool {
        let previousPlaylists = playlists
        let previousItems = itemsByPlaylistID

        do {
            let playlistRecords = try fetchPlaylistRecords(playlistID, modelContext: modelContext)
            let itemRecords = try fetchItemRecords(playlistID, modelContext: modelContext)
            let deletesLoadedState = playlists.contains { $0.playlistID == playlistID }
                || itemsByPlaylistID[playlistID] != nil
            guard deletesLoadedState || !playlistRecords.isEmpty || !itemRecords.isEmpty else {
                return true
            }

            playlists.removeAll { $0.playlistID == playlistID }
            itemsByPlaylistID[playlistID] = nil
            for record in itemRecords {
                modelContext.delete(record)
            }
            for record in playlistRecords {
                modelContext.delete(record)
            }
            // Inserted even when memory listed the playlist and no row was
            // left: another device may still hold rows, and the tombstone is
            // what keeps the delete from being undone when they sync back.
            modelContext.insert(PlaylistTombstoneRecord(playlistID: playlistID, deletedAt: now()))
            try saveSyncedStore(modelContext)
            smartEvaluations.remove(playlistID)
            didMutate()
            return true
        } catch {
            modelContext.rollback()
            playlists = previousPlaylists
            itemsByPlaylistID = previousItems
            lastErrorMessage = "Unable to delete the playlist: \(error.localizedDescription)"
            return false
        }
    }

    /// Appends the episodes that are not already members, in order, and
    /// returns how many were added.
    @discardableResult
    func add(
        _ episodes: [EpisodeListItemSnapshot],
        to playlistID: String,
        modelContext: ModelContext
    ) -> Int {
        let failure = episodes.count == 1
            ? "Unable to add the episode to the playlist"
            : "Unable to add episodes to the playlist"
        guard let summary = playlists.first(where: { $0.playlistID == playlistID }) else {
            lastErrorMessage = "\(failure) because the playlist no longer exists."
            return 0
        }
        guard summary.kind == .manual else {
            lastErrorMessage = "\(failure) because smart playlists choose their own episodes."
            return 0
        }

        let previousPlaylists = playlists
        let previousItems = itemsByPlaylistID

        do {
            let playlistRecords = try fetchPlaylistRecords(playlistID, modelContext: modelContext)
            guard !playlistRecords.isEmpty else {
                lastErrorMessage = "\(failure) because the playlist no longer exists."
                return 0
            }

            var itemRecords = try listedItemRecords(
                playlistID,
                playlistRecords: playlistRecords,
                modelContext: modelContext
            )
            // Listed rows count as members too: an identity re-key can change a
            // row's episode behind the loaded items. A row a tombstone shadows
            // is not a member, so adding its episode again keeps the new row.
            var memberEpisodeIDs = Set(itemRecords.map(\.episodeID))
            memberEpisodeIDs.formUnion((itemsByPlaylistID[playlistID] ?? []).map(\.episodeID))
            let newEpisodes = episodes.filter { memberEpisodeIDs.insert($0.episodeID).inserted }
            guard !newEpisodes.isEmpty else {
                return 0
            }

            let timestamp = now()
            Self.renumberIfUnordered(itemRecords, timestamp: timestamp)
            let keys = Self.keys(
                count: newEpisodes.count,
                between: itemRecords.last?.sortKey,
                and: nil
            )
            for (episode, sortKey) in zip(newEpisodes, keys) {
                let record = PlaylistItemRecord(
                    playlistID: playlistID,
                    episodeID: episode.episodeID,
                    podcastID: episode.podcastID,
                    sortKey: sortKey,
                    addedAt: timestamp,
                    updatedAt: timestamp,
                    episodeTitle: episode.title,
                    podcastTitle: episode.podcastTitle,
                    artworkURL: episode.artworkURL,
                    audioURL: episode.audioURL,
                    duration: episode.duration,
                    publishedAt: episode.publishedAt
                )
                modelContext.insert(record)
                itemRecords.append(record)
            }
            Self.renumberIfTooLong(itemRecords, timestamp: timestamp)

            try commitItems(
                itemRecords,
                playlistRecords: playlistRecords,
                in: playlistID,
                timestamp: timestamp,
                modelContext: modelContext
            )
            didMutate()
            return newEpisodes.count
        } catch {
            modelContext.rollback()
            playlists = previousPlaylists
            itemsByPlaylistID = previousItems
            lastErrorMessage = "\(failure): \(error.localizedDescription)"
            return 0
        }
    }

    @discardableResult
    func remove(
        itemIDs: Set<String>,
        from playlistID: String,
        modelContext: ModelContext
    ) -> Bool {
        guard !itemIDs.isEmpty else {
            return true
        }

        let previousPlaylists = playlists
        let previousItems = itemsByPlaylistID

        do {
            let itemRecords = try fetchItemRecords(playlistID, modelContext: modelContext)
            let loadedItems = itemsByPlaylistID[playlistID] ?? []
            guard itemRecords.contains(where: { itemIDs.contains($0.itemID) })
                || loadedItems.contains(where: { itemIDs.contains($0.itemID) })
            else {
                return true
            }
            // Memory counts too: a row can already be gone while memory still
            // lists it, and its pair still needs a tombstone. An empty
            // `episodeID` is not a pair, so such a row goes by `itemID` alone.
            let removedEpisodeIDs = Set(
                itemRecords.lazy.filter { itemIDs.contains($0.itemID) }.map(\.episodeID)
            ).union(
                loadedItems.lazy.filter { itemIDs.contains($0.itemID) }.map(\.episodeID)
            ).subtracting([""])

            let playlistRecords = try fetchPlaylistRecords(playlistID, modelContext: modelContext)
            let timestamp = now()
            // Removal is by episode, not by row: a twin row of the pair that
            // another device minted under another `itemID` goes too, or it
            // would list the episode again until repair.
            var remainingRecords: [PlaylistItemRecord] = []
            var deletedRowCount = 0
            for record in itemRecords {
                if itemIDs.contains(record.itemID) || removedEpisodeIDs.contains(record.episodeID) {
                    modelContext.delete(record)
                    deletedRowCount += 1
                } else {
                    remainingRecords.append(record)
                }
            }
            guard deletedRowCount > 0 || !removedEpisodeIDs.isEmpty || !playlistRecords.isEmpty else {
                // Only memory listed a keyless row whose playlist row is gone
                // too: nothing synced would change, so there is no save to make.
                itemsByPlaylistID[playlistID] = loadedItems.filter { !itemIDs.contains($0.itemID) }
                didMutate()
                return true
            }
            for episodeID in removedEpisodeIDs {
                modelContext.insert(
                    PlaylistTombstoneRecord(
                        playlistID: playlistID,
                        episodeID: episodeID,
                        deletedAt: timestamp
                    )
                )
            }
            try commitItems(
                listedRows(
                    playlistRecords: playlistRecords,
                    itemRecords: remainingRecords,
                    modelContext: modelContext
                ).items,
                playlistRecords: playlistRecords,
                in: playlistID,
                timestamp: timestamp,
                modelContext: modelContext
            )
            didMutate()
            return true
        } catch {
            modelContext.rollback()
            playlists = previousPlaylists
            itemsByPlaylistID = previousItems
            let operation = itemIDs.count == 1
                ? "Unable to remove the episode from the playlist"
                : "Unable to remove episodes from the playlist"
            lastErrorMessage = "\(operation): \(error.localizedDescription)"
            return false
        }
    }

    /// Moves items within the loaded order. Only the moved rows get new keys,
    /// unless a key grows past the renumber threshold, in which case the whole
    /// playlist is renumbered in the same save.
    @discardableResult
    func move(
        fromOffsets offsets: IndexSet,
        toOffset destination: Int,
        in playlistID: String,
        modelContext: ModelContext
    ) -> Bool {
        let staleMessage = "Unable to reorder the playlist because it changed. Try again."
        let currentItems = itemsByPlaylistID[playlistID] ?? []
        guard let firstOffset = offsets.first, let lastOffset = offsets.last else {
            return true
        }
        guard firstOffset >= 0,
              lastOffset < currentItems.count,
              (0...currentItems.count).contains(destination)
        else {
            lastErrorMessage = staleMessage
            return false
        }

        let movedItems = offsets.map { currentItems[$0] }
        var reorderedItems = currentItems
        for offset in offsets.reversed() {
            reorderedItems.remove(at: offset)
        }
        let insertionIndex = destination - offsets.count(where: { $0 < destination })
        reorderedItems.insert(contentsOf: movedItems, at: insertionIndex)
        guard reorderedItems.map(\.itemID) != currentItems.map(\.itemID) else {
            return true
        }

        let previousPlaylists = playlists
        let previousItems = itemsByPlaylistID

        do {
            let playlistRecords = try fetchPlaylistRecords(playlistID, modelContext: modelContext)
            // Twin and shadowed rows are left for repair; comparing them would
            // refuse every reorder until it runs.
            let itemRecords = try listedItemRecords(
                playlistID,
                playlistRecords: playlistRecords,
                modelContext: modelContext
            )
            guard itemRecords.map(\.itemID) == currentItems.map(\.itemID) else {
                // The rows changed behind the loaded order (an identity re-key
                // can delete a duplicate row, an import can land) and no reload
                // has run yet; adopting them lets the retry succeed.
                publishItems(itemRecords, in: playlistID, updatedAt: nil)
                onPlaylistsChanged?()
                lastErrorMessage = staleMessage
                return false
            }

            let recordsByItemID = Dictionary(
                itemRecords.map { ($0.itemID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let orderedRecords = reorderedItems.compactMap { recordsByItemID[$0.itemID] }
            let timestamp = now()
            if Self.keysAreOrdered(itemRecords) {
                let movedRange = insertionIndex..<(insertionIndex + movedItems.count)
                let lower = insertionIndex > 0 ? orderedRecords[insertionIndex - 1].sortKey : nil
                let upper = movedRange.upperBound < orderedRecords.count
                    ? orderedRecords[movedRange.upperBound].sortKey
                    : nil
                let keys = Self.keys(count: movedItems.count, between: lower, and: upper)
                for (record, sortKey) in zip(orderedRecords[movedRange], keys) {
                    record.sortKey = sortKey
                    record.updatedAt = timestamp
                }
                Self.renumberIfTooLong(orderedRecords, timestamp: timestamp)
            } else {
                Self.renumber(orderedRecords, timestamp: timestamp)
            }

            try commitItems(
                orderedRecords,
                playlistRecords: playlistRecords,
                in: playlistID,
                timestamp: timestamp,
                modelContext: modelContext
            )
            didMutate()
            return true
        } catch {
            modelContext.rollback()
            playlists = previousPlaylists
            itemsByPlaylistID = previousItems
            lastErrorMessage = "Unable to reorder the playlist: \(error.localizedDescription)"
            return false
        }
    }

    /// Reorders a manual playlist by each row's stored publication date and
    /// renumbers it in one save. Equal and missing dates keep their current
    /// relative order; an already-sorted playlist is left untouched.
    @discardableResult
    func sortItems(
        in playlistID: String,
        by order: PlaylistItemSortOrder,
        modelContext: ModelContext
    ) -> Bool {
        let failure = "Unable to sort the playlist"
        guard let summary = playlists.first(where: { $0.playlistID == playlistID }) else {
            lastErrorMessage = "\(failure) because the playlist no longer exists."
            return false
        }
        guard summary.kind == .manual else {
            lastErrorMessage = "Smart playlists choose their own order."
            return false
        }

        let currentItems = itemsByPlaylistID[playlistID] ?? []
        let sortedItems = order.sorted(currentItems, date: \.publishedAt)
        guard sortedItems.map(\.itemID) != currentItems.map(\.itemID) else {
            return true
        }

        let previousPlaylists = playlists
        let previousItems = itemsByPlaylistID

        do {
            let playlistRecords = try fetchPlaylistRecords(playlistID, modelContext: modelContext)
            let itemRecords = try listedItemRecords(
                playlistID,
                playlistRecords: playlistRecords,
                modelContext: modelContext
            )
            guard itemRecords.map(\.itemID) == currentItems.map(\.itemID) else {
                // Same recovery as `move`: adopt the rows so the retry succeeds.
                publishItems(itemRecords, in: playlistID, updatedAt: nil)
                onPlaylistsChanged?()
                lastErrorMessage = "\(failure) because it changed. Try again."
                return false
            }

            let orderedRecords = order.sorted(itemRecords, date: \.publishedAt)
            let timestamp = now()
            Self.renumber(orderedRecords, timestamp: timestamp)
            try commitItems(
                orderedRecords,
                playlistRecords: playlistRecords,
                in: playlistID,
                timestamp: timestamp,
                modelContext: modelContext
            )
            didMutate()
            return true
        } catch {
            modelContext.rollback()
            playlists = previousPlaylists
            itemsByPlaylistID = previousItems
            lastErrorMessage = "\(failure): \(error.localizedDescription)"
            return false
        }
    }

    func playlistIDs(containing episodeID: String) -> Set<String> {
        Set(
            itemsByPlaylistID.compactMap { playlistID, items in
                items.contains { $0.episodeID == episodeID } ? playlistID : nil
            }
        )
    }

    func resolvedItems(
        in playlistID: String,
        resolve: (String) -> EpisodeListItemSnapshot?
    ) -> [PlaylistResolvedItem] {
        (itemsByPlaylistID[playlistID] ?? []).map { item in
            PlaylistResolvedItem(item: item, snapshot: resolve(item.episodeID))
        }
    }

    /// Played state lives in the library's progress index, so these figures
    /// are computed on demand instead of being held on the summaries. Manual
    /// playlists only: a smart playlist's figures come from its evaluation.
    func counts(for playlistID: String, isPlayed: (String) -> Bool) -> PlaylistCounts {
        let items = itemsByPlaylistID[playlistID] ?? []
        let unplayedItems = items.filter { !isPlayed($0.episodeID) }
        return PlaylistCounts(
            itemCount: items.count,
            unplayedCount: unplayedItems.count,
            remainingDuration: Self.totalDuration(of: unplayedItems)
        )
    }

    func resetAfterDataNuke() {
        playlists = []
        itemsByPlaylistID = [:]
        smartEvaluations.removeAll()
        stagedIdentityMigration = nil
        lastErrorMessage = nil
        onPlaylistsChanged?()
    }

    func consumeLastErrorMessage() -> String? {
        defer { lastErrorMessage = nil }
        return lastErrorMessage
    }

    private func updatePlaylist(
        _ playlistID: String,
        failure: String,
        modelContext: ModelContext,
        change: (inout PlaylistSummary) -> Void
    ) -> Bool {
        guard let index = playlists.firstIndex(where: { $0.playlistID == playlistID }) else {
            lastErrorMessage = "\(failure) because the playlist no longer exists."
            return false
        }

        var updatedSummary = playlists[index]
        change(&updatedSummary)
        guard updatedSummary != playlists[index] else {
            return true
        }

        let previousPlaylists = playlists

        do {
            let records = try fetchPlaylistRecords(playlistID, modelContext: modelContext)
            guard !records.isEmpty else {
                lastErrorMessage = "\(failure) because the playlist no longer exists."
                return false
            }

            updatedSummary.updatedAt = now()
            for record in records {
                record.name = updatedSummary.name
                record.ruleJSON = updatedSummary.ruleJSON
                record.hidesPlayed = updatedSummary.hidesPlayed
                record.updatedAt = updatedSummary.updatedAt
            }
            playlists[index] = updatedSummary
            playlists = Self.sorted(playlists, by: sortOrder)
            try saveSyncedStore(modelContext)
            didMutate()
            return true
        } catch {
            modelContext.rollback()
            playlists = previousPlaylists
            lastErrorMessage = "\(failure): \(error.localizedDescription)"
            return false
        }
    }

    /// Publishes the playlist's rows in their new order, touches the
    /// playlist's `updatedAt`, and saves.
    private func commitItems(
        _ orderedRecords: [PlaylistItemRecord],
        playlistRecords: [PlaylistRecord],
        in playlistID: String,
        timestamp: Date,
        modelContext: ModelContext
    ) throws {
        publishItems(orderedRecords, in: playlistID, updatedAt: timestamp)
        for record in playlistRecords {
            record.updatedAt = timestamp
        }
        try saveSyncedStore(modelContext)
    }

    /// Rebuilding the items from the rows rather than patching them keeps
    /// memory in step with anything that changed the rows since load.
    private func publishItems(
        _ orderedRecords: [PlaylistItemRecord],
        in playlistID: String,
        updatedAt: Date?
    ) {
        let items = orderedRecords.map { Self.item(from: $0) }
        itemsByPlaylistID[playlistID] = items
        guard let index = playlists.firstIndex(where: { $0.playlistID == playlistID }) else {
            return
        }

        var summary = Self.summary(playlists[index], items: items)
        if let updatedAt {
            summary.updatedAt = updatedAt
        }
        playlists[index] = summary
        playlists = Self.sorted(playlists, by: sortOrder)
    }

    private func fetchPlaylistRecords(
        _ playlistID: String,
        modelContext: ModelContext
    ) throws -> [PlaylistRecord] {
        let targetPlaylistID = playlistID
        return try modelContext.fetch(
            FetchDescriptor<PlaylistRecord>(
                predicate: #Predicate { record in
                    record.playlistID == targetPlaylistID
                }
            )
        )
    }

    private func fetchItemRecords(
        _ playlistID: String,
        modelContext: ModelContext
    ) throws -> [PlaylistItemRecord] {
        let targetPlaylistID = playlistID
        return try modelContext.fetch(
            FetchDescriptor<PlaylistItemRecord>(
                predicate: #Predicate { record in
                    record.playlistID == targetPlaylistID
                },
                sortBy: Self.itemSortDescriptors
            )
        )
    }

    private func listedItemRecords(
        _ playlistID: String,
        playlistRecords: [PlaylistRecord],
        modelContext: ModelContext
    ) throws -> [PlaylistItemRecord] {
        try listedRows(
            playlistRecords: playlistRecords,
            itemRecords: fetchItemRecords(playlistID, modelContext: modelContext),
            modelContext: modelContext
        ).items
    }

    /// Both tables in full: they are small, and memory must match every row.
    private func fetchListedState(modelContext: ModelContext) throws -> ListedState {
        let listed = try listedRows(
            playlistRecords: modelContext.fetch(FetchDescriptor<PlaylistRecord>()),
            itemRecords: modelContext.fetch(
                FetchDescriptor<PlaylistItemRecord>(sortBy: Self.itemSortDescriptors)
            ),
            modelContext: modelContext
        )
        let itemsByID = Dictionary(grouping: listed.items.map { Self.item(from: $0) }, by: \.playlistID)
        let summaries = listed.playlists.map { record in
            Self.summary(from: record, items: itemsByID[record.playlistID] ?? [])
        }
        return (Self.sorted(summaries, by: sortOrder), itemsByID, listed.needsRepair)
    }

    /// The rows a duplicate repair pass would keep, found without changing
    /// the store, so memory never lists a twin or a tombstoned row that the
    /// next pass deletes, and a mutation never rewrites one. Twin groups and
    /// tombstones follow `PlaylistSyncRepairer`: one row per `playlistID` and
    /// per (`playlistID`, `episodeID`), the smallest `dedupeUUID` winning for
    /// playlists and the newest `addedAt` for items, and rows with an empty
    /// key standing alone. `itemRecords` arrive in the
    /// store's item order and keep it. An item whose playlist is not listed is
    /// left out: repair never deletes it, and it reappears once its playlist
    /// row syncs in.
    private func listedRows(
        playlistRecords: [PlaylistRecord],
        itemRecords: [PlaylistItemRecord],
        modelContext: ModelContext
    ) throws -> (playlists: [PlaylistRecord], items: [PlaylistItemRecord], needsRepair: Bool) {
        let tombstones = PlaylistTombstoneIndex(
            try modelContext.fetch(FetchDescriptor<PlaylistTombstoneRecord>())
        )
        var needsRepair = false

        var listedPlaylists: [PlaylistRecord] = []
        var playlistGroups: [String: [PlaylistRecord]] = [:]
        for record in playlistRecords {
            if tombstones.shadowsPlaylist(record.playlistID) {
                needsRepair = true
            } else if record.playlistID.isEmpty {
                listedPlaylists.append(record)
            } else {
                playlistGroups[record.playlistID, default: []].append(record)
            }
        }
        for group in playlistGroups.values {
            needsRepair = needsRepair || group.count > 1
            if let keep = Self.listedPlaylist(in: group) {
                listedPlaylists.append(keep)
            }
        }

        var survivingItems: [PlaylistItemRecord] = []
        var itemGroups: [PlaylistTombstoneIndex.ItemKey: [PlaylistItemRecord]] = [:]
        for record in itemRecords {
            guard !tombstones.shadowsItem(
                playlistID: record.playlistID,
                episodeID: record.episodeID,
                addedAt: record.addedAt
            ) else {
                needsRepair = true
                continue
            }
            survivingItems.append(record)
            guard !record.playlistID.isEmpty, !record.episodeID.isEmpty else {
                continue
            }
            let key = PlaylistTombstoneIndex.ItemKey(
                playlistID: record.playlistID,
                episodeID: record.episodeID
            )
            itemGroups[key, default: []].append(record)
        }
        var unlistedItems: Set<ObjectIdentifier> = []
        for group in itemGroups.values where group.count > 1 {
            needsRepair = true
            let keep = Self.listedItem(in: group)
            for record in group where record !== keep {
                unlistedItems.insert(ObjectIdentifier(record))
            }
        }

        let listedPlaylistIDs = Set(listedPlaylists.map(\.playlistID))
        let listedItems = survivingItems.filter { record in
            listedPlaylistIDs.contains(record.playlistID)
                && !unlistedItems.contains(ObjectIdentifier(record))
        }
        return (listedPlaylists, listedItems, needsRepair)
    }

    /// The copy `PlaylistSyncRepairer` keeps, or, when no copy carries an
    /// identity, the freshest copy, whose content its fresh row carries.
    private static func listedPlaylist(in group: [PlaylistRecord]) -> PlaylistRecord? {
        PlaylistSyncRepairer.keptPlaylist(in: group)
            ?? group.min(by: PlaylistSyncRepairer.isFresherPlaylist)
    }

    private static func listedItem(in group: [PlaylistItemRecord]) -> PlaylistItemRecord? {
        PlaylistSyncRepairer.keptItem(in: group)
            ?? group.min(by: PlaylistSyncRepairer.isFresherItem)
    }

    private func didMutate() {
        lastErrorMessage = nil
        onPlaylistsChanged?()
    }

    /// Keys are plain-`String` ordered; the default `.localizedStandard`
    /// comparator is numeric-aware and would misorder them.
    private static var itemSortDescriptors: [SortDescriptor<PlaylistItemRecord>] {
        [
            SortDescriptor(\.sortKey, comparator: .lexical),
            SortDescriptor(\.addedAt),
            SortDescriptor(\.itemID, comparator: .lexical)
        ]
    }

    private static func keysAreOrdered(_ records: [PlaylistItemRecord]) -> Bool {
        records.allSatisfy { PlaylistSortKey.isValid($0.sortKey) }
            && !zip(records, records.dropFirst()).contains { $0.sortKey >= $1.sortKey }
    }

    /// Rows with empty, malformed, tied or over-long keys (a model default,
    /// or a future synced edit) cannot anchor a midpoint, so the playlist is
    /// renumbered in its current order first.
    private static func renumberIfUnordered(_ records: [PlaylistItemRecord], timestamp: Date) {
        guard !keysAreOrdered(records)
            || records.contains(where: { PlaylistSortKey.needsRenumbering($0.sortKey) })
        else {
            return
        }
        renumber(records, timestamp: timestamp)
    }

    private static func renumberIfTooLong(_ records: [PlaylistItemRecord], timestamp: Date) {
        guard records.contains(where: { PlaylistSortKey.needsRenumbering($0.sortKey) }) else {
            return
        }
        renumber(records, timestamp: timestamp)
    }

    private static func renumber(_ records: [PlaylistItemRecord], timestamp: Date) {
        for (record, sortKey) in zip(records, PlaylistSortKey.renumbered(count: records.count)) {
            guard record.sortKey != sortKey else {
                continue
            }
            record.sortKey = sortKey
            record.updatedAt = timestamp
        }
    }

    /// `count` increasing keys strictly between `lower` and `upper`, split
    /// from the middle out so a block insert stays as short as a single one.
    private static func keys(count: Int, between lower: String?, and upper: String?) -> [String] {
        guard count > 0 else {
            return []
        }

        let middle = PlaylistSortKey.between(lower, upper)
        let lowerCount = count / 2
        return keys(count: lowerCount, between: lower, and: middle)
            + [middle]
            + keys(count: count - lowerCount - 1, between: middle, and: upper)
    }

    private static func sorted(
        _ playlists: [PlaylistSummary],
        by order: PlaylistSortOrder
    ) -> [PlaylistSummary] {
        playlists.sorted { lhs, rhs in
            switch order {
            case .name:
                let comparison = lhs.name.localizedStandardCompare(rhs.name)
                if comparison != .orderedSame {
                    return comparison == .orderedAscending
                }
            case .recentlyUpdated:
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
            }
            return lhs.playlistID < rhs.playlistID
        }
    }

    private static func summary(
        from record: PlaylistRecord,
        items: [PlaylistItem]
    ) -> PlaylistSummary {
        PlaylistSummary(
            playlistID: record.playlistID,
            name: record.name,
            kind: record.kind,
            ruleJSON: record.ruleJSON,
            rule: rule(for: record),
            hidesPlayed: record.hidesPlayed,
            tintKey: record.tintKey,
            origin: record.origin,
            itemCount: items.count,
            totalDuration: totalDuration(of: items),
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            coverPodcastIDs: coverPodcastIDs(for: items)
        )
    }

    /// A smart row without stored JSON reads as the default rule; only a
    /// stored rule that fails to decode is unreadable.
    private static func rule(for record: PlaylistRecord) -> PlaylistRule? {
        guard record.kind == .smart else {
            return nil
        }
        guard let ruleJSON = record.ruleJSON else {
            return .default
        }
        return PlaylistRule.decode(ruleJSON)
    }

    private static func summary(
        _ summary: PlaylistSummary,
        items: [PlaylistItem]
    ) -> PlaylistSummary {
        var updatedSummary = summary
        updatedSummary.itemCount = items.count
        updatedSummary.totalDuration = totalDuration(of: items)
        updatedSummary.coverPodcastIDs = coverPodcastIDs(for: items)
        return updatedSummary
    }

    private static func totalDuration(of items: [PlaylistItem]) -> TimeInterval {
        items.reduce(0) { total, item in
            total + (item.duration ?? 0)
        }
    }

    private static func coverPodcastIDs(for items: [PlaylistItem]) -> [String] {
        var podcastIDs: [String] = []
        for item in items where !podcastIDs.contains(item.podcastID) {
            podcastIDs.append(item.podcastID)
            if podcastIDs.count == 4 {
                break
            }
        }
        return podcastIDs
    }

    private static func item(from record: PlaylistItemRecord) -> PlaylistItem {
        PlaylistItem(
            itemID: record.itemID,
            playlistID: record.playlistID,
            episodeID: record.episodeID,
            podcastID: record.podcastID,
            sortKey: record.sortKey,
            addedAt: record.addedAt,
            updatedAt: record.updatedAt,
            episodeTitle: record.episodeTitle,
            podcastTitle: record.podcastTitle,
            artworkURL: record.artworkURL,
            audioURL: record.audioURL,
            duration: record.duration,
            publishedAt: record.publishedAt
        )
    }

    private static func item(
        _ item: PlaylistItem,
        episodeID: String,
        podcastID: String
    ) -> PlaylistItem {
        PlaylistItem(
            itemID: item.itemID,
            playlistID: item.playlistID,
            episodeID: episodeID,
            podcastID: podcastID,
            sortKey: item.sortKey,
            addedAt: item.addedAt,
            updatedAt: item.updatedAt,
            episodeTitle: item.episodeTitle,
            podcastTitle: item.podcastTitle,
            artworkURL: item.artworkURL,
            audioURL: item.audioURL,
            duration: item.duration,
            publishedAt: item.publishedAt
        )
    }
}

extension PlaylistStore: EpisodeIdentitySidecarMigrating {
    /// Stages the loaded items' re-key for the rows
    /// `EpisodeIdentityMigrationApplier` rewrites in the same pass. Memory
    /// only: the applier owns the rows and the save, and the staged state
    /// is published by `finishEpisodeSidecarMigration` only once that save
    /// has committed, so memory never runs ahead of storage. The collision
    /// rule is the applier's, per playlist: a successor already present
    /// drops the departed item instead of leaving two members for one
    /// episode.
    func migrateEpisodeSidecars(
        from oldEpisodeID: String,
        to newEpisodeID: String,
        canonicalPodcastID: String,
        modelContext: ModelContext
    ) throws {
        var staged = stagedIdentityMigration
            ?? StagedIdentityMigration(playlists: playlists, itemsByPlaylistID: itemsByPlaylistID)
        for (playlistID, items) in staged.itemsByPlaylistID
            where items.contains(where: { $0.episodeID == oldEpisodeID }) {
            let hasSuccessor = items.contains { $0.episodeID == newEpisodeID }
            var didRekey = false
            var migratedItems: [PlaylistItem] = []
            migratedItems.reserveCapacity(items.count)
            for item in items {
                guard item.episodeID == oldEpisodeID else {
                    migratedItems.append(item)
                    continue
                }
                guard !hasSuccessor, !didRekey else {
                    continue
                }
                migratedItems.append(Self.item(item, episodeID: newEpisodeID, podcastID: canonicalPodcastID))
                didRekey = true
            }
            staged.itemsByPlaylistID[playlistID] = migratedItems
            if let index = staged.playlists.firstIndex(where: { $0.playlistID == playlistID }) {
                staged.playlists[index] = Self.summary(staged.playlists[index], items: migratedItems)
            }
            staged.didChange = true
        }
        stagedIdentityMigration = staged
    }

    /// A smart rule names its shows by feed URL, so a moved subscription's
    /// URL is swapped in every rule that lists it; otherwise the show would
    /// silently drop out of the rule. Rows and loaded summaries follow the
    /// episode re-key's staging, and `updatedAt` is untouched because a
    /// re-key is not an edit. A rule this build cannot read is left alone.
    func migrateFeedSidecars(
        from oldCanonicalFeedURL: String,
        to newCanonicalFeedURL: String,
        modelContext: ModelContext
    ) throws {
        func isMoved(_ podcastID: String) -> Bool {
            URLCanonicalizer.canonicalString(forRawString: podcastID) == oldCanonicalFeedURL
        }

        for record in try modelContext.fetch(FetchDescriptor<PlaylistRecord>()) where record.kind == .smart {
            guard let migratedRule = PlaylistRule.decode(record.ruleJSON)?
                .replacingPodcastIDs(where: isMoved, with: newCanonicalFeedURL)
            else {
                continue
            }
            record.ruleJSON = migratedRule.encodedJSON()
        }

        var staged = stagedIdentityMigration
            ?? StagedIdentityMigration(playlists: playlists, itemsByPlaylistID: itemsByPlaylistID)
        for index in staged.playlists.indices {
            guard let migratedRule = staged.playlists[index].rule?
                .replacingPodcastIDs(where: isMoved, with: newCanonicalFeedURL)
            else {
                continue
            }
            staged.playlists[index].rule = migratedRule
            staged.playlists[index].ruleJSON = migratedRule.encodedJSON()
            staged.didChange = true
        }
        stagedIdentityMigration = staged
    }

    func finishEpisodeSidecarMigration(committed: Bool) {
        guard let staged = stagedIdentityMigration else {
            return
        }
        stagedIdentityMigration = nil
        guard committed, staged.didChange else {
            return
        }
        itemsByPlaylistID = staged.itemsByPlaylistID
        playlists = Self.sorted(staged.playlists, by: sortOrder)
        onPlaylistsChanged?()
    }
}

/// The loaded state with a reconciliation's re-keys applied, held back until
/// the reconciliation's save commits.
private struct StagedIdentityMigration {
    var playlists: [PlaylistSummary]
    var itemsByPlaylistID: [String: [PlaylistItem]]
    var didChange = false
}
