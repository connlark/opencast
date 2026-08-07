import Foundation
import Observation
import SwiftData
import SwiftUI

@Observable
final class UpNextQueueStore {
    private(set) var items: [UpNextQueueItem] = []
    private(set) var lastErrorMessage: String?

    @ObservationIgnored var onQueueChanged: (() -> Void)?
    @ObservationIgnored private let saveModelContext: (ModelContext) throws -> Void

    init(
        saveModelContext: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.saveModelContext = saveModelContext
    }

    func load(
        resolveEpisode: (String) -> EpisodeListItemSnapshot?,
        mayPruneUnresolved: Bool,
        modelContext: ModelContext
    ) {
        do {
            let records = try modelContext.fetch(
                FetchDescriptor<UpNextQueueItemRecord>(
                    sortBy: [
                        SortDescriptor(\.sequence),
                        SortDescriptor(\.enqueuedAt),
                        SortDescriptor(\.episodeID)
                    ]
                )
            )
            let loadedItems: [UpNextQueueItem]
            if mayPruneUnresolved {
                var resolvedItems: [UpNextQueueItem] = []
                var seenEpisodeIDs: Set<String> = []
                var recordsChanged = false

                for record in records {
                    guard resolveEpisode(record.episodeID) != nil,
                          seenEpisodeIDs.insert(record.episodeID).inserted
                    else {
                        modelContext.delete(record)
                        recordsChanged = true
                        continue
                    }

                    let sequence = resolvedItems.count
                    if record.sequence != sequence {
                        record.sequence = sequence
                        recordsChanged = true
                    }
                    resolvedItems.append(Self.item(from: record, sequence: sequence))
                }

                if recordsChanged {
                    try saveModelContext(modelContext)
                }
                loadedItems = resolvedItems
            } else {
                loadedItems = records.map { Self.item(from: $0, sequence: $0.sequence) }
            }
            items = loadedItems
            lastErrorMessage = nil
            onQueueChanged?()
        } catch {
            modelContext.rollback()
            lastErrorMessage = "Unable to load Up Next: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func enqueueNext(
        _ episode: EpisodeListItemSnapshot,
        modelContext: ModelContext
    ) -> Bool {
        enqueue(episode, atFront: true, modelContext: modelContext)
    }

    @discardableResult
    func enqueueLast(
        _ episode: EpisodeListItemSnapshot,
        modelContext: ModelContext
    ) -> Bool {
        enqueue(episode, atFront: false, modelContext: modelContext)
    }

    @discardableResult
    func remove(episodeID: String, modelContext: ModelContext) -> Bool {
        remove(episodeIDs: [episodeID], modelContext: modelContext)
    }

    @discardableResult
    func remove(episodeIDs: Set<String>, modelContext: ModelContext) -> Bool {
        guard !episodeIDs.isEmpty else {
            return true
        }

        do {
            let records = try modelContext.fetch(FetchDescriptor<UpNextQueueItemRecord>())
                .filter { episodeIDs.contains($0.episodeID) }
            let removesLoadedItems = items.contains { episodeIDs.contains($0.episodeID) }
            guard removesLoadedItems || !records.isEmpty else {
                return true
            }

            let previousItems = items
            items.removeAll { episodeIDs.contains($0.episodeID) }
            do {
                for record in records {
                    modelContext.delete(record)
                }
                try saveModelContext(modelContext)
                didMutate()
                return true
            } catch {
                modelContext.rollback()
                items = previousItems
                throw error
            }
        } catch {
            let operation = episodeIDs.count == 1
                ? "Unable to remove the episode from Up Next"
                : "Unable to remove episodes from Up Next"
            lastErrorMessage = "\(operation): \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func removeAll(forPodcastID podcastID: String, modelContext: ModelContext) -> Bool {
        do {
            let descriptor = FetchDescriptor<UpNextQueueItemRecord>(
                predicate: #Predicate { $0.podcastID == podcastID }
            )
            let records = try modelContext.fetch(descriptor)
            let removesLoadedItems = items.contains { $0.podcastID == podcastID }
            guard removesLoadedItems || !records.isEmpty else {
                return true
            }

            let previousItems = items
            items.removeAll { $0.podcastID == podcastID }
            do {
                for record in records {
                    modelContext.delete(record)
                }
                try saveModelContext(modelContext)
                didMutate()
                return true
            } catch {
                modelContext.rollback()
                items = previousItems
                throw error
            }
        } catch {
            lastErrorMessage = "Unable to update Up Next: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func reorderVisibleEpisodeIDs(
        _ orderedEpisodeIDs: [String],
        modelContext: ModelContext
    ) -> Bool {
        let orderedEpisodeIDSet = Set(orderedEpisodeIDs)
        let currentVisibleEpisodeIDs = items.compactMap { item in
            orderedEpisodeIDSet.contains(item.episodeID) ? item.episodeID : nil
        }
        guard orderedEpisodeIDSet.count == orderedEpisodeIDs.count,
              Set(currentVisibleEpisodeIDs) == orderedEpisodeIDSet,
              currentVisibleEpisodeIDs.count == orderedEpisodeIDs.count
        else {
            lastErrorMessage = "Unable to reorder Up Next because the queue changed. Try again."
            return false
        }
        guard currentVisibleEpisodeIDs != orderedEpisodeIDs else {
            return true
        }

        let previousItems = items
        var reorderedEpisodeIDs = orderedEpisodeIDs.makeIterator()
        for index in items.indices where orderedEpisodeIDSet.contains(items[index].episodeID) {
            guard let episodeID = reorderedEpisodeIDs.next(),
                  let replacement = previousItems.first(where: { $0.episodeID == episodeID })
            else {
                items = previousItems
                lastErrorMessage = "Unable to reorder Up Next because the queue changed. Try again."
                return false
            }
            items[index] = replacement
        }
        renumberItems()

        do {
            try persistCurrentOrder(modelContext: modelContext)
            didMutate()
            return true
        } catch {
            modelContext.rollback()
            items = previousItems
            lastErrorMessage = "Unable to reorder Up Next: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func clear(modelContext: ModelContext) -> Bool {
        do {
            let records = try modelContext.fetch(FetchDescriptor<UpNextQueueItemRecord>())
            guard !items.isEmpty || !records.isEmpty else {
                return true
            }

            let previousItems = items
            items = []
            do {
                for record in records {
                    modelContext.delete(record)
                }
                try saveModelContext(modelContext)
                didMutate()
                return true
            } catch {
                modelContext.rollback()
                items = previousItems
                throw error
            }
        } catch {
            lastErrorMessage = "Unable to clear Up Next: \(error.localizedDescription)"
            return false
        }
    }

    func popNext(modelContext: ModelContext) -> UpNextQueuePopResult {
        guard let nextItem = items.first else {
            return .empty
        }

        let previousItems = items
        items.removeFirst()
        do {
            try deleteRecords(episodeID: nextItem.episodeID, modelContext: modelContext)
            try saveModelContext(modelContext)
            didMutate()
            return .item(nextItem)
        } catch {
            modelContext.rollback()
            items = previousItems
            let message = "Unable to advance Up Next: \(error.localizedDescription)"
            lastErrorMessage = message
            return .failure(message)
        }
    }

    func contains(episodeID: String) -> Bool {
        items.contains { $0.episodeID == episodeID }
    }

    func resetAfterDataNuke() {
        items = []
        lastErrorMessage = nil
        onQueueChanged?()
    }

    func consumeLastErrorMessage() -> String? {
        defer { lastErrorMessage = nil }
        return lastErrorMessage
    }

    private func enqueue(
        _ episode: EpisodeListItemSnapshot,
        atFront: Bool,
        modelContext: ModelContext
    ) -> Bool {
        let previousItems = items
        items.removeAll { $0.episodeID == episode.episodeID }
        let sequence = atFront
            ? (items.first?.sequence ?? 1) - 1
            : (items.last?.sequence ?? -1) + 1
        let item = UpNextQueueItem(
            episodeID: episode.episodeID,
            podcastID: episode.podcastID,
            sequence: sequence,
            enqueuedAt: .now
        )
        if atFront {
            items.insert(item, at: 0)
        } else {
            items.append(item)
        }

        do {
            try deleteRecords(episodeID: episode.episodeID, modelContext: modelContext)
            modelContext.insert(
                UpNextQueueItemRecord(
                    episodeID: item.episodeID,
                    podcastID: item.podcastID,
                    sequence: item.sequence,
                    enqueuedAt: item.enqueuedAt
                )
            )
            try saveModelContext(modelContext)
            didMutate()
            return true
        } catch {
            modelContext.rollback()
            items = previousItems
            lastErrorMessage = "Unable to add the episode to Up Next: \(error.localizedDescription)"
            return false
        }
    }

    private func persistCurrentOrder(modelContext: ModelContext) throws {
        let records = try modelContext.fetch(FetchDescriptor<UpNextQueueItemRecord>())
        var recordsByEpisodeID = Dictionary(grouping: records, by: \.episodeID)

        for item in items {
            guard let matches = recordsByEpisodeID.removeValue(forKey: item.episodeID),
                  let record = matches.first
            else {
                modelContext.insert(
                    UpNextQueueItemRecord(
                        episodeID: item.episodeID,
                        podcastID: item.podcastID,
                        sequence: item.sequence,
                        enqueuedAt: item.enqueuedAt
                    )
                )
                continue
            }

            record.sequence = item.sequence
            for duplicate in matches.dropFirst() {
                modelContext.delete(duplicate)
            }
        }

        for orphanedRecords in recordsByEpisodeID.values {
            for record in orphanedRecords {
                modelContext.delete(record)
            }
        }
        try saveModelContext(modelContext)
    }

    private func deleteRecords(episodeID: String, modelContext: ModelContext) throws {
        let descriptor = FetchDescriptor<UpNextQueueItemRecord>(
            predicate: #Predicate { $0.episodeID == episodeID }
        )
        for record in try modelContext.fetch(descriptor) {
            modelContext.delete(record)
        }
    }

    private func renumberItems() {
        for index in items.indices {
            items[index].sequence = index
        }
    }

    private func didMutate() {
        lastErrorMessage = nil
        onQueueChanged?()
    }

    private static func item(
        from record: UpNextQueueItemRecord,
        sequence: Int
    ) -> UpNextQueueItem {
        UpNextQueueItem(
            episodeID: record.episodeID,
            podcastID: record.podcastID,
            sequence: sequence,
            enqueuedAt: record.enqueuedAt
        )
    }
}
