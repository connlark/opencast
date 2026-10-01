import Foundation
import Observation
import SwiftData

/// Device-local playlist collection preferences. Every load and save runs in
/// its own short-lived context: a failed save is discarded with that context
/// instead of lingering as a dirty row that a later unrelated save would
/// commit, and a preference save never flushes another context's pending
/// synced edits. Published values change only after a save succeeds.
@Observable
final class PlaylistDisplaySettingsStore {
    static let sortOrderPreferenceKey = "playlists.sortOrder"

    private(set) var sortOrder = PlaylistSortOrder.recentlyUpdated
    private(set) var lastErrorMessage: String?

    @ObservationIgnored private let save: (ModelContext) throws -> Void

    /// `save` is the test seam for preference saves.
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
