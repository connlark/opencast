import Foundation
import Observation
import SwiftData

/// Device-local Library display preferences. Every load and save runs in its
/// own short-lived context: a failed save is discarded with that context
/// instead of lingering as a dirty row that a later unrelated save would
/// commit, and a preference save never flushes another context's pending
/// synced edits. Published values change only after a save succeeds.
@Observable
final class LibraryDisplaySettingsStore {
    static let layoutPreferenceKey = "library.layout"
    static let sortOrderPreferenceKey = "library.sortOrder"
    static let showsNewEpisodeBadgesPreferenceKey = "library.showsNewEpisodeBadges"

    private(set) var layout = LibraryLayoutPreference.automatic
    private(set) var sortOrder = LibrarySortOrder.title
    private(set) var showsNewEpisodeBadges = true
    private(set) var lastErrorMessage: String?

    @ObservationIgnored private let save: (ModelContext) throws -> Void

    /// `save` is the test seam for preference saves.
    init(save: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.save = save
    }

    func load(modelContext: ModelContext) {
        let context = ModelContext(modelContext.container)
        do {
            layout = try storedValue(forKey: Self.layoutPreferenceKey, context: context)
                .flatMap(LibraryLayoutPreference.init(rawValue:)) ?? .automatic
            sortOrder = try storedValue(forKey: Self.sortOrderPreferenceKey, context: context)
                .flatMap(LibrarySortOrder.init(rawValue:)) ?? .title
            showsNewEpisodeBadges = try storedValue(forKey: Self.showsNewEpisodeBadgesPreferenceKey, context: context)
                .flatMap(Bool.init) ?? true
            lastErrorMessage = nil
        } catch {
            layout = .automatic
            sortOrder = .title
            showsNewEpisodeBadges = true
            lastErrorMessage = "Unable to load Library settings: \(error.localizedDescription)"
        }
    }

    /// Automatic is the absence of a choice, so selecting it deletes every
    /// row for the key; an older duplicate can't resurface as the winner.
    @discardableResult
    func setLayout(_ layout: LibraryLayoutPreference, modelContext: ModelContext) -> Bool {
        guard self.layout != layout else {
            return true
        }
        guard persist(
            layout == .automatic ? nil : layout.rawValue,
            forKey: Self.layoutPreferenceKey,
            modelContext: modelContext,
            failureDescription: "Unable to update Library layout"
        ) else {
            return false
        }

        self.layout = layout
        return true
    }

    @discardableResult
    func setSortOrder(_ sortOrder: LibrarySortOrder, modelContext: ModelContext) -> Bool {
        guard self.sortOrder != sortOrder else {
            return true
        }
        guard persist(
            sortOrder.rawValue,
            forKey: Self.sortOrderPreferenceKey,
            modelContext: modelContext,
            failureDescription: "Unable to update Library sort order"
        ) else {
            return false
        }

        self.sortOrder = sortOrder
        return true
    }

    @discardableResult
    func setShowsNewEpisodeBadges(_ showsNewEpisodeBadges: Bool, modelContext: ModelContext) -> Bool {
        guard self.showsNewEpisodeBadges != showsNewEpisodeBadges else {
            return true
        }
        guard persist(
            String(showsNewEpisodeBadges),
            forKey: Self.showsNewEpisodeBadgesPreferenceKey,
            modelContext: modelContext,
            failureDescription: "Unable to update new episode badges"
        ) else {
            return false
        }

        self.showsNewEpisodeBadges = showsNewEpisodeBadges
        return true
    }

    func clearLastError() {
        lastErrorMessage = nil
    }

    /// Writes `value` for `key`, or deletes every row for `key` when nil.
    private func persist(
        _ value: String?,
        forKey key: String,
        modelContext: ModelContext,
        failureDescription: String
    ) -> Bool {
        let context = ModelContext(modelContext.container)
        context.autosaveEnabled = false
        do {
            if let value {
                try LocalPreferenceRecord.upsert(key: key, value: value, modelContext: context)
            } else {
                try LocalPreferenceRecord.deletePreferences(forKey: key, modelContext: context)
            }
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
