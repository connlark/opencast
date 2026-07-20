import Foundation
import Observation
import SwiftData

@Observable
final class PodcastEpisodeListSettingsStore {
    private static let sortOrderKeyPrefix = "podcastDetail.sortOrder."
    private static let filterKeyPrefix = "podcastDetail.filter."

    private var sortOrdersByPodcastID: [String: PodcastEpisodeSortOrder] = [:]
    private var filtersByPodcastID: [String: PodcastEpisodeFilter] = [:]
    private var lastError: PodcastEpisodeListSettingsError?

    var lastErrorMessage: String? {
        lastError?.message
    }

    func load(modelContext: ModelContext) {
        do {
            let records = try modelContext.fetch(
                FetchDescriptor<LocalPreferenceRecord>(
                    sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
                )
            )
            var loadedSortOrders: [String: PodcastEpisodeSortOrder] = [:]
            var loadedFilters: [String: PodcastEpisodeFilter] = [:]
            var seenSortOrderPodcastIDs: Set<String> = []
            var seenFilterPodcastIDs: Set<String> = []

            for record in records {
                if record.key.hasPrefix(Self.sortOrderKeyPrefix) {
                    let podcastID = String(record.key.dropFirst(Self.sortOrderKeyPrefix.count))
                    guard !podcastID.isEmpty, seenSortOrderPodcastIDs.insert(podcastID).inserted else {
                        continue
                    }
                    loadedSortOrders[podcastID] = PodcastEpisodeSortOrder(rawValue: record.value) ?? .newestFirst
                } else if record.key.hasPrefix(Self.filterKeyPrefix) {
                    let podcastID = String(record.key.dropFirst(Self.filterKeyPrefix.count))
                    guard !podcastID.isEmpty, seenFilterPodcastIDs.insert(podcastID).inserted else {
                        continue
                    }
                    loadedFilters[podcastID] = PodcastEpisodeFilter(rawValue: record.value) ?? .all
                }
            }

            sortOrdersByPodcastID = loadedSortOrders
            filtersByPodcastID = loadedFilters
            lastError = nil
        } catch {
            sortOrdersByPodcastID = [:]
            filtersByPodcastID = [:]
            lastError = PodcastEpisodeListSettingsError(
                message: "Unable to load podcast episode settings: \(error.localizedDescription)",
                podcastID: nil
            )
        }
    }

    func sortOrder(forPodcastID podcastID: String) -> PodcastEpisodeSortOrder {
        sortOrdersByPodcastID[podcastID] ?? .newestFirst
    }

    func filter(forPodcastID podcastID: String) -> PodcastEpisodeFilter {
        filtersByPodcastID[podcastID] ?? .all
    }

    func errorMessage(forPodcastID podcastID: String) -> String? {
        lastError?.message(forPodcastID: podcastID)
    }

    @discardableResult
    func setSortOrder(
        _ sortOrder: PodcastEpisodeSortOrder,
        forPodcastID podcastID: String,
        modelContext: ModelContext
    ) -> Bool {
        guard self.sortOrder(forPodcastID: podcastID) != sortOrder else {
            lastError = lastError?.clearing(forPodcastID: podcastID)
            return true
        }

        let previousValue = sortOrdersByPodcastID[podcastID]
        sortOrdersByPodcastID[podcastID] = sortOrder
        do {
            try LocalPreferenceRecord.upsert(
                key: Self.sortOrderKeyPrefix + podcastID,
                value: sortOrder.rawValue,
                modelContext: modelContext
            )
            try modelContext.save()
            lastError = lastError?.clearing(forPodcastID: podcastID)
            return true
        } catch {
            sortOrdersByPodcastID[podcastID] = previousValue
            lastError = PodcastEpisodeListSettingsError(
                message: "Unable to update episode sort order: \(error.localizedDescription)",
                podcastID: podcastID
            )
            return false
        }
    }

    @discardableResult
    func setFilter(
        _ filter: PodcastEpisodeFilter,
        forPodcastID podcastID: String,
        modelContext: ModelContext
    ) -> Bool {
        guard self.filter(forPodcastID: podcastID) != filter else {
            lastError = lastError?.clearing(forPodcastID: podcastID)
            return true
        }

        let previousValue = filtersByPodcastID[podcastID]
        filtersByPodcastID[podcastID] = filter
        do {
            try LocalPreferenceRecord.upsert(
                key: Self.filterKeyPrefix + podcastID,
                value: filter.rawValue,
                modelContext: modelContext
            )
            try modelContext.save()
            lastError = lastError?.clearing(forPodcastID: podcastID)
            return true
        } catch {
            filtersByPodcastID[podcastID] = previousValue
            lastError = PodcastEpisodeListSettingsError(
                message: "Unable to update episode filter: \(error.localizedDescription)",
                podcastID: podcastID
            )
            return false
        }
    }

    @discardableResult
    func removePreferences(forPodcastID podcastID: String, modelContext: ModelContext) -> Bool {
        let previousSortOrder = sortOrdersByPodcastID.removeValue(forKey: podcastID)
        let previousFilter = filtersByPodcastID.removeValue(forKey: podcastID)

        do {
            try LocalPreferenceRecord.deletePreferences(
                forKey: Self.sortOrderKeyPrefix + podcastID,
                modelContext: modelContext
            )
            try LocalPreferenceRecord.deletePreferences(
                forKey: Self.filterKeyPrefix + podcastID,
                modelContext: modelContext
            )
            try modelContext.save()
            lastError = lastError?.clearing(forPodcastID: podcastID)
            return true
        } catch {
            sortOrdersByPodcastID[podcastID] = previousSortOrder
            filtersByPodcastID[podcastID] = previousFilter
            lastError = PodcastEpisodeListSettingsError(
                message: "Unable to remove podcast episode settings: \(error.localizedDescription)",
                podcastID: podcastID
            )
            return false
        }
    }
}
