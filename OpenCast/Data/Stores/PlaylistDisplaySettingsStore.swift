import Foundation
import Observation
import SwiftData

/// Every load and save uses its own short-lived context: a failed save is discarded with it
/// instead of lingering for a later unrelated save to commit, and a save never flushes another
/// context's pending synced edits.
@Observable
final class PlaylistDisplaySettingsStore {
    static let sortOrderPreferenceKey = "playlists.sortOrder"

    private(set) var sortOrder = PlaylistSortOrder.recentlyUpdated
    private(set) var lastErrorMessage: String?

    @ObservationIgnored private let save: (ModelContext) throws -> Void

    init(save: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.save = save
    }

    func load(modelContext: ModelContext) {
        let context = ModelContext(modelContext.container)
        do {
            sortOrder = try storedValue(forKey: Self.sortOrderPreferenceKey, context: context)
                .flatMap(PlaylistSortOrder.init(rawValue:)) ?? .recentlyUpdated
            lastErrorMessage = nil
        } catch {
            sortOrder = .recentlyUpdated
            lastErrorMessage = "Unable to load playlist settings: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func setSortOrder(_ sortOrder: PlaylistSortOrder, modelContext: ModelContext) -> Bool {
        guard self.sortOrder != sortOrder else {
            return true
        }
        guard persist(
            sortOrder.rawValue,
            forKey: Self.sortOrderPreferenceKey,
            modelContext: modelContext,
            failureDescription: "Unable to update playlist sort order"
        ) else {
            return false
        }

        self.sortOrder = sortOrder
        return true
    }

    func clearLastError() {
        lastErrorMessage = nil
    }

    private func persist(
        _ value: String,
        forKey key: String,
        modelContext: ModelContext,
        failureDescription: String
    ) -> Bool {
        let context = ModelContext(modelContext.container)
        context.autosaveEnabled = false
        do {
            try LocalPreferenceRecord.upsert(key: key, value: value, modelContext: context)
            try save(context)
            lastErrorMessage = nil
            return true
        } catch {
            lastErrorMessage = "\(failureDescription): \(error.localizedDescription)"
            return false
        }
    }

    private func storedValue(forKey key: String, context: ModelContext) throws -> String? {
        try LocalPreferenceRecord.preference(forKey: key, modelContext: context)?.value
    }
}
